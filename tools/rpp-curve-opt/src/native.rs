//! REAPER MIDI_GetAllEvts batch adapter. Reuse the RPP lane optimizer while
//! retaining every non-target message, flag, ordering and absolute source tick.
use crate::rpp::{self, Stats};
use std::collections::BTreeSet;

#[derive(Clone, Debug, PartialEq)]
struct Event {
    tick: i64,
    flags: u8,
    msg: Vec<u8>,
}

fn events(data: &[u8]) -> Result<Vec<Event>, String> {
    let mut result = Vec::new();
    let mut pos = 0;
    let mut tick = 0_i64;
    while pos < data.len() {
        if data.len() - pos < 9 {
            return Err("Truncated native MIDI header".into());
        }
        let delta = i32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
        if delta < 0 {
            return Err("Unsorted MIDI source; sort it before optimizing".into());
        }
        tick += i64::from(delta);
        let flags = data[pos + 4];
        let len = u32::from_le_bytes(data[pos + 5..pos + 9].try_into().unwrap()) as usize;
        pos += 9;
        let end = pos
            .checked_add(len)
            .filter(|&end| end <= data.len())
            .ok_or("Truncated MIDI message")?;
        result.push(Event {
            tick,
            flags,
            msg: data[pos..end].to_vec(),
        });
        pos = end;
    }
    Ok(result)
}
fn write_event(out: &mut Vec<u8>, e: &Event, previous: &mut i64) -> Result<(), String> {
    let delta = i32::try_from(e.tick - *previous).map_err(|_| "MIDI offset out of range")?;
    out.extend(delta.to_le_bytes());
    out.push(e.flags);
    out.extend((e.msg.len() as u32).to_le_bytes());
    out.extend(&e.msg);
    *previous = e.tick;
    Ok(())
}
fn token(e: &Event) -> &str {
    match e.flags & 3 {
        0 => "E",
        1 => "e",
        2 => "Em",
        _ => "em",
    }
}
fn encoded_msg(e: &Event) -> Vec<u8> {
    let mut msg = e.msg.clone();
    // RPP's event decoder expects at least two message bytes. Padding is only
    // an adapter token: the original empty/short message is restored verbatim.
    if msg.len() < 2 {
        msg.resize(2, 0);
    }
    msg
}
fn bezier(msg: &[u8]) -> Option<f32> {
    (msg.len() == 12 && msg.starts_with(b"\xff\x0fCCBZ "))
        .then(|| f32::from_le_bytes(msg[8..12].try_into().unwrap()))
}
fn selected(e: &Event, ccs: &BTreeSet<u8>) -> bool {
    e.msg.len() == 3 && e.msg[0] & 0xf0 == 0xb0 && ccs.contains(&e.msg[1])
}

fn optimize(
    data: &[u8],
    ppq: u32,
    ccs: &BTreeSet<u8>,
    tolerance: f64,
    jitter: bool,
    gestures: bool,
    stats: &mut Stats,
) -> Result<Vec<u8>, String> {
    let original = events(data)?;
    let mut text = format!("<SOURCE MIDI\nHASDATA 1 {ppq} QN\n");
    let mut previous = 0;
    for (i, e) in original.iter().enumerate() {
        text.push_str(&format!("{} {}", token(e), e.tick - previous));
        previous = e.tick;
        for byte in encoded_msg(e) {
            text.push_str(&format!(" {byte:02x}"));
        }
        text.push('\n');
        let shape = e.flags >> 4;
        if shape > 0 && e.msg.first().is_some_and(|s| s & 0xf0 == 0xb0) {
            let tension = original
                .get(i + 1)
                .and_then(|next| bezier(&next.msg))
                .unwrap_or(0.0);
            text.push_str(&format!("ENV {shape} 0 {tension}\n"));
        }
    }
    text.push_str(">\n");
    let optimized = rpp::source(&text, ccs, tolerance, jitter, gestures, stats)?;
    let lines: Vec<_> = optimized.lines().collect();
    let mut cursor = 0;
    let mut tick = 0;
    let mut output = Vec::new();
    let mut previous = 0;
    for (i, line) in lines.iter().enumerate() {
        let p: Vec<_> = line.split_whitespace().collect();
        if !matches!(p.first().copied(), Some("E" | "e" | "Em" | "em")) {
            continue;
        }
        tick += p[1]
            .parse::<i64>()
            .map_err(|_| "Invalid optimized MIDI tick")?;
        let msg: Vec<u8> = p[2..]
            .iter()
            .map(|s| u8::from_str_radix(s, 16).map_err(|_| "Invalid MIDI byte"))
            .collect::<Result<_, _>>()?;
        while cursor < original.len()
            && !(original[cursor].tick == tick
                && token(&original[cursor]) == p[0]
                && encoded_msg(&original[cursor]) == msg)
        {
            if !selected(&original[cursor], ccs) {
                return Err("Optimizer attempted to remove non-target MIDI".into());
            }
            cursor += 1;
        }
        let mut event = original
            .get(cursor)
            .ok_or("Optimizer inserted or moved MIDI")?
            .clone();
        cursor += 1;
        let mut insert = None;
        if selected(&event, ccs) {
            if let Some(env) = lines.get(i + 1).filter(|line| line.starts_with("ENV ")) {
                let fields: Vec<_> = env.split_whitespace().collect();
                let shape = fields[1].parse::<u8>().map_err(|_| "Invalid shape")?;
                if event.flags >> 4 != 5 && shape == 5 {
                    let tension = fields[3].parse::<f32>().map_err(|_| "Invalid tension")?;
                    let mut msg = b"\xff\x0fCCBZ \0".to_vec();
                    msg.extend(tension.to_le_bytes());
                    insert = Some(Event {
                        tick,
                        flags: 0,
                        msg,
                    });
                }
                event.flags = (event.flags & 15) | (shape << 4);
            }
        }
        write_event(&mut output, &event, &mut previous)?;
        if let Some(event) = insert {
            write_event(&mut output, &event, &mut previous)?;
        }
    }
    if original[cursor..].iter().any(|e| !selected(e, ccs)) {
        return Err("Optimizer truncated MIDI".into());
    }
    Ok(output)
}

// GCC1, u32 count, then { u32 source PPQ, u64 byte length, raw MIDI buffer }.
pub fn batch(
    data: &[u8],
    ccs: &BTreeSet<u8>,
    tolerance: f64,
    jitter: bool,
    gestures: bool,
    threads: usize,
) -> Result<(Vec<u8>, Stats), String> {
    if data.len() < 8 || &data[..4] != b"GCC1" {
        return Err("Invalid native MIDI batch".into());
    }
    let count = u32::from_le_bytes(data[4..8].try_into().unwrap());
    let mut pos = 8;
    let mut jobs = Vec::new();
    for _ in 0..count {
        if data.len() - pos < 12 {
            return Err("Truncated MIDI batch".into());
        }
        let ppq = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
        let len = u64::from_le_bytes(data[pos + 4..pos + 12].try_into().unwrap());
        pos += 12;
        if ppq == 0 || len > (data.len() - pos) as u64 {
            return Err("Invalid MIDI batch length/PPQ".into());
        }
        let end = pos + len as usize;
        jobs.push((ppq, &data[pos..end]));
        pos = end;
    }
    if pos != data.len() {
        return Err("Trailing MIDI batch data".into());
    }
    let results = crate::parallel::map(&jobs, threads, |&(ppq, source)| {
        let mut local = Stats::default();
        optimize(source, ppq, ccs, tolerance, jitter, gestures, &mut local)
            .map(|result| (ppq, result, local))
    })?;
    let mut output = data[..8].to_vec();
    let mut stats = Stats::default();
    for result in results {
        let (ppq, result, local) = result?;
        output.extend(ppq.to_le_bytes());
        output.extend((result.len() as u64).to_le_bytes());
        output.extend(result);
        stats.merge(local);
    }
    Ok((output, stats))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_notes_text_sysex_flags_and_existing_curves() {
        let e = vec![
            Event {
                tick: 0,
                flags: 4,
                msg: vec![0x90, 60, 100],
            },
            Event {
                tick: 0,
                flags: 1,
                msg: vec![0xb0, 11, 10],
            },
            Event {
                tick: 10,
                flags: 1,
                msg: vec![0xb0, 11, 20],
            },
            Event {
                tick: 15,
                flags: 0,
                msg: b"\xff\x01hello".to_vec(),
            },
            Event {
                tick: 20,
                flags: 1,
                msg: vec![0xb0, 11, 30],
            },
            Event {
                tick: 25,
                flags: 0,
                msg: vec![0xf0, 1, 2, 0xf7],
            },
            Event {
                tick: 30,
                flags: 1,
                msg: vec![0xb0, 11, 40],
            },
            Event {
                tick: 40,
                flags: 2,
                msg: vec![0x80, 60, 0],
            },
            Event {
                tick: 50,
                flags: 16,
                msg: vec![0xb0, 1, 50],
            },
            Event {
                tick: 60,
                flags: 0,
                msg: vec![],
            },
        ];
        let mut input = Vec::new();
        let mut tick = 0;
        for event in &e {
            write_event(&mut input, event, &mut tick).unwrap();
        }
        let result = optimize(
            &input,
            960,
            &[11].into(),
            2.,
            false,
            true,
            &mut Stats::default(),
        )
        .unwrap();
        let out = events(&result).unwrap();
        assert_eq!(
            e.iter()
                .filter(|e| !selected(e, &[11].into()))
                .cloned()
                .collect::<Vec<_>>(),
            out.iter()
                .filter(|e| !selected(e, &[11].into()))
                .cloned()
                .collect::<Vec<_>>()
        );
        assert_eq!(out.iter().filter(|e| selected(e, &[11].into())).count(), 2);
    }
    #[test]
    fn rejects_truncated_and_unsorted_buffers() {
        assert!(events(&[0, 1]).is_err());
        let mut raw = Vec::new();
        write_event(
            &mut raw,
            &Event {
                tick: -1,
                flags: 0,
                msg: vec![],
            },
            &mut 0,
        )
        .unwrap();
        assert!(events(&raw).is_err());
    }
    #[test]
    fn native_bezier_metadata_round_trips() {
        let mut input = Vec::new();
        let mut previous = 0;
        for i in 0..=100 {
            let value = (10.0
                + 100.0
                    * crate::curve::Model {
                        shape: 5,
                        tension: 0.45,
                    }
                    .value(i as f64 / 100.0))
            .round() as u8;
            write_event(
                &mut input,
                &Event {
                    tick: i * 10,
                    flags: 17, // selected, explicitly linear: refit rather than protect
                    msg: vec![0xb0, 11, value],
                },
                &mut previous,
            )
            .unwrap();
        }
        let ccs = [11].into();
        let result = optimize(&input, 960, &ccs, 2., false, true, &mut Stats::default()).unwrap();
        let decoded = events(&result).unwrap();
        assert!(decoded.iter().any(|e| e.flags >> 4 == 5));
        assert!(decoded.iter().any(|e| bezier(&e.msg).is_some()));
        assert!(decoded.iter().filter(|e| selected(e, &ccs)).count() <= 3);
        let again = optimize(&result, 960, &ccs, 2., false, true, &mut Stats::default()).unwrap();
        assert_eq!(result, again);
    }
}
