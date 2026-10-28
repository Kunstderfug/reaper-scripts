use crate::curve::{self, Point};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug)]
pub struct Block {
    pub start: usize,
    pub end: usize,
    pub header: String,
    pub track: String,
    pub snapshot: bool,
}

pub fn blocks(input: &str) -> Result<Vec<Block>, String> {
    let mut result = Vec::<Block>::new();
    let mut stack = Vec::<usize>::new();
    let mut offset = 0;
    for line in input.split_inclusive('\n') {
        let s = line.trim();
        if s.starts_with('<') {
            let snapshot =
                s.starts_with("<SWSSNAPSHOT ") || stack.iter().any(|&i| result[i].snapshot);
            let track = stack
                .iter()
                .rev()
                .find_map(|&i| {
                    if result[i].header.split_whitespace().next() == Some("<TRACK") {
                        Some(result[i].track.clone())
                    } else {
                        None
                    }
                })
                .unwrap_or_default();
            result.push(Block {
                start: offset,
                end: 0,
                header: s.to_string(),
                track,
                snapshot,
            });
            stack.push(result.len() - 1);
        } else if s == ">" {
            let i = stack.pop().ok_or("Unexpected closing block")?;
            result[i].end = offset + line.len();
        } else if let Some(&i) = stack.last() {
            if result[i].header.split_whitespace().next() == Some("<TRACK")
                && s.starts_with("NAME ")
            {
                result[i].track = s[5..].trim_matches('"').to_string();
            }
        }
        offset += line.len();
    }
    if !stack.is_empty() {
        return Err("Unclosed RPP block".into());
    }
    Ok(result)
}

#[derive(Default, Debug)]
pub struct Stats {
    pub before: BTreeMap<u8, usize>,
    pub after: BTreeMap<u8, usize>,
    pub shapes: BTreeMap<u8, usize>,
    pub sources: usize,
    pub unsupported: usize,
    pub snapshots: usize,
    pub snapshot_bytes: usize,
    pub max_error: f64,
    pub quiet_error: f64,
    pub jitter_removed: usize,
    pub jitter_deviation: f64,
    pub fade_removed: usize,
    pub fade_deviation: f64,
}

struct Event {
    tick: i64,
    fields: Vec<String>,
    shaped: bool,
    keep: bool,
    model: Option<curve::Model>,
}

pub fn source(
    input: &str,
    ccs: &BTreeSet<u8>,
    tolerance: f64,
    de_jitter: bool,
    gestures: bool,
    stats: &mut Stats,
) -> Result<String, String> {
    let lines: Vec<_> = input.split_inclusive('\n').collect();
    // Text/SysEx events have their own relative offsets. Never rewrite an
    // unrecognized timed-event format and silently shift later notes.
    if lines
        .iter()
        .any(|l| l.trim_start().starts_with("<X") || l.trim_start().starts_with("<x"))
    {
        stats.unsupported += 1;
        return Ok(input.to_string());
    }
    let mut ppq = 960;
    let mut tick = 0_i64;
    let mut events = BTreeMap::<usize, Event>::new();
    let mut lanes = BTreeMap::<(u8, u8), Vec<usize>>::new();
    for (i, line) in lines.iter().enumerate() {
        let p: Vec<_> = line.split_whitespace().collect();
        if p.first() == Some(&"HASDATA") && p.len() > 2 {
            ppq = p[2].parse().map_err(|_| "Invalid MIDI PPQ")?;
        }
        if !matches!(p.first().copied(), Some("E" | "e" | "Em" | "em")) {
            continue;
        }
        if p.len() < 4 {
            return Err("Truncated MIDI event".into());
        }
        tick = tick
            .checked_add(p[1].parse::<i64>().map_err(|_| "Invalid event delta")?)
            .ok_or("MIDI tick overflow")?;
        let status = u8::from_str_radix(p[2], 16).map_err(|_| "Invalid MIDI status")?;
        if status & 0xf0 == 0xb0 && p.len() >= 5 {
            let cc = u8::from_str_radix(p[3], 16).map_err(|_| "Invalid controller")?;
            if ccs.contains(&cc) {
                lanes.entry((status & 15, cc)).or_default().push(i);
            }
        }
        events.insert(
            i,
            Event {
                tick,
                fields: p.iter().map(|s| s.to_string()).collect(),
                shaped: lines
                    .get(i + 1)
                    .is_some_and(|l| l.trim_start().starts_with("ENV ")),
                keep: true,
                model: None,
            },
        );
    }
    stats.sources += 1;
    let activity_events: Vec<_> = events
        .values()
        .filter_map(|e| {
            Some((
                e.tick,
                u8::from_str_radix(e.fields.get(2)?, 16).ok()?,
                u8::from_str_radix(e.fields.get(3)?, 16).ok()?,
                u8::from_str_radix(e.fields.get(4)?, 16).ok()?,
            ))
        })
        .collect();
    let quiet = crate::activity::quiet_regions(&activity_events, ppq);
    for ((_, cc), ids) in &lanes {
        *stats.before.entry(*cc).or_default() += ids.len();
        if ids.len() < 3 {
            *stats.after.entry(*cc).or_default() += ids.len();
            continue;
        }
        let points: Vec<_> = ids
            .iter()
            .map(|id| {
                let e = &events[id];
                Ok(Point {
                    tick: e.tick,
                    value: u8::from_str_radix(&e.fields[4], 16).map_err(|_| "Invalid CC value")?
                        as f64,
                    shaped: e.shaped,
                    muted: e.fields[0].contains('m'),
                    repaired_fade: false,
                })
            })
            .collect::<Result<_, String>>()?;
        let (mut dropped, deviation) = if de_jitter {
            crate::jitter::detect(&points, ppq)
        } else {
            (BTreeSet::new(), 0.0)
        };
        stats.jitter_removed += dropped.len();
        stats.jitter_deviation = stats.jitter_deviation.max(deviation);
        let fade = if de_jitter {
            crate::fade::repair(&points, ppq)
        } else {
            crate::fade::Repair::default()
        };
        stats.fade_removed += fade.removed.difference(&dropped).count();
        stats.fade_deviation = stats.fade_deviation.max(fade.deviation);
        dropped.extend(&fade.removed);
        let surviving: Vec<_> = (0..points.len()).filter(|i| !dropped.contains(i)).collect();
        let cleaned: Vec<_> = surviving
            .iter()
            .map(|&i| Point {
                repaired_fade: fade.smooth.contains(&i),
                ..points[i]
            })
            .collect();
        let segments = if gestures {
            if quiet.is_empty() {
                crate::gesture::optimize(&cleaned, ppq, tolerance)
            } else {
                crate::gesture::with_quiet_regions(&cleaned, ppq, tolerance, &quiet)
            }
        } else {
            curve::optimize(&cleaned, ppq, tolerance)
        };
        let mut kept = BTreeSet::new();
        for seg in segments {
            kept.extend([surviving[seg.first], surviving[seg.last]]);
            events.get_mut(&ids[surviving[seg.first]]).unwrap().model = seg.model;
            if gestures
                && quiet
                    .iter()
                    .any(|&(a, b)| cleaned[seg.first].tick >= a && cleaned[seg.last].tick <= b)
            {
                stats.quiet_error = stats.quiet_error.max(seg.error);
            } else {
                stats.max_error = stats.max_error.max(seg.error);
            }
            if let Some(m) = seg.model {
                *stats.shapes.entry(m.shape).or_default() += 1;
            }
        }
        *stats.after.entry(*cc).or_default() += kept.len();
        for (j, id) in ids.iter().enumerate() {
            events.get_mut(id).unwrap().keep = kept.contains(&j);
        }
    }
    let mut output = String::with_capacity(input.len());
    let mut previous_tick = 0;
    for (i, line) in lines.iter().enumerate() {
        if let Some(e) = events.get(&i) {
            if !e.keep {
                continue;
            }
            let mut fields = e.fields.clone();
            fields[1] = (e.tick - previous_tick).to_string();
            previous_tick = e.tick;
            let indent = &line[..line.len() - line.trim_start().len()];
            let newline = if line.ends_with("\r\n") { "\r\n" } else { "\n" };
            output.push_str(indent);
            output.push_str(&fields.join(" "));
            output.push_str(newline);
            if let Some(model) = e.model {
                output.push_str(&format!(
                    "{indent}ENV {} 0 {:.2}{newline}",
                    model.shape, model.tension
                ));
            }
        } else {
            output.push_str(line);
        }
    }
    Ok(output)
}

pub fn transform(
    input: &str,
    ccs: &BTreeSet<u8>,
    tolerance: f64,
    track: Option<&str>,
    remove_snapshots: bool,
    de_jitter: bool,
    gestures: bool,
) -> Result<(String, Stats), String> {
    let blocks = blocks(input)?;
    if let Some(selected) = track.filter(|_| !ccs.is_empty()) {
        let mut pools = BTreeMap::<&str, BTreeSet<&str>>::new();
        for b in &blocks {
            if b.header == "<SOURCE MIDI" && !b.snapshot {
                for line in input[b.start..b.end].lines() {
                    if let Some(pool) = line.trim().strip_prefix("POOLEDEVTS ") {
                        pools.entry(pool).or_default().insert(&b.track);
                    }
                }
            }
        }
        if pools
            .values()
            .any(|tracks| tracks.contains(selected) && tracks.len() > 1)
        {
            return Err("Selected track shares pooled MIDI with another track; unpool it before a track-only edit".into());
        }
    }
    let mut stats = Stats::default();
    let mut changes = Vec::new();
    let mut matched_track = track.is_none();
    for b in blocks {
        if track == Some(b.track.as_str()) {
            matched_track = true;
        }
        if remove_snapshots && b.header.starts_with("<SWSSNAPSHOT ") {
            changes.push((b.start, b.end, String::new()));
            stats.snapshots += 1;
            stats.snapshot_bytes += b.end - b.start;
        } else if b.header == "<SOURCE MIDI"
            && !b.snapshot
            && !ccs.is_empty()
            && track.is_none_or(|t| t == b.track)
        {
            let new = source(
                &input[b.start..b.end],
                ccs,
                tolerance,
                de_jitter,
                gestures,
                &mut stats,
            )?;
            changes.push((b.start, b.end, new));
        }
    }
    if !matched_track {
        return Err(format!("Track not found: {}", track.unwrap()));
    }
    changes.sort_by_key(|c| c.0);
    let mut result = String::new();
    let mut end = 0;
    for (a, b, s) in changes {
        if a < end {
            return Err("Overlapping changes in RPP".into());
        }
        result.push_str(&input[end..a]);
        result.push_str(&s);
        end = b;
    }
    result.push_str(&input[end..]);
    Ok((result, stats))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keeps_note_positions_and_other_lanes_when_removing_points() {
        let s = "<SOURCE MIDI\nHASDATA 1 960 QN\nE 0 b0 0b 00\nE 10 b0 0b 01\nE 5 90 3c 64\nE 5 b0 0b 02\nE 5 b0 0d 40\nE 5 b0 0b 03\nE 5 80 3c 00\n>\n";
        let r = source(s, &[11].into(), 0.01, false, false, &mut Stats::default()).unwrap();
        assert!(r.contains("E 15 90 3c 64"));
        assert!(r.contains("E 10 b0 0d 40"));
        assert!(r.contains("E 5 80 3c 00"));
        assert_eq!(r.matches("b0 0b").count(), 2);
    }
    #[test]
    fn snapshots_only_leaves_current_tracks_byte_identical() {
        let track = "<TRACK {A}\nNAME \"VIOLIN\"\n>\n";
        let input = format!("<REAPER_PROJECT 0.1\n{track}<EXTENSIONS\n<SWSSNAPSHOT \"Mix\"\n<TRACK {{A}}\n>\n>\n>\n>\n");
        let (r, stats) =
            transform(&input, &BTreeSet::new(), 2.0, None, true, false, false).unwrap();
        assert_eq!(stats.snapshots, 1);
        assert!(r.contains(track));
        assert!(!r.contains("SWSSNAPSHOT"));
    }
    #[test]
    fn refuses_unknown_track() {
        assert!(transform(
            "<REAPER_PROJECT 0.1\n>\n",
            &[11].into(),
            2.,
            Some("missing"),
            true,
            false,
            false
        )
        .is_err());
    }

    #[test]
    fn refuses_cross_track_pool_in_track_only_edit() {
        let input = "<REAPER_PROJECT 0.1\n<TRACK\nNAME A\n<SOURCE MIDI\nPOOLEDEVTS {P}\n>\n>\n<TRACK\nNAME B\n<SOURCE MIDI\nPOOLEDEVTS {P}\n>\n>\n>\n";
        assert!(
            transform(input, &[11].into(), 2., Some("A"), true, false, false)
                .unwrap_err()
                .contains("pooled")
        );
    }
}
