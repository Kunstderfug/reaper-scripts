//! Conservative note-free regions for locally contained MIDI performances.
use std::collections::{BTreeMap, VecDeque};

pub fn quiet_regions(events: &[(i64, u8, u8, u8)], ppq: i64) -> Vec<(i64, i64)> {
    // CC-only routing, unmatched notes and sustain make local silence uncertain.
    if events
        .iter()
        .any(|&(_, s, cc, v)| s & 0xf0 == 0xb0 && [64, 66].contains(&cc) && v >= 64)
    {
        return Vec::new();
    }
    let mut starts: BTreeMap<(u8, u8), VecDeque<i64>> = BTreeMap::new();
    let mut active = Vec::new();
    for &(tick, status, key, value) in events {
        let kind = status & 0xf0;
        let id = (status & 15, key);
        if kind == 0x90 && value > 0 {
            starts.entry(id).or_default().push_back(tick);
        } else if kind == 0x80 || (kind == 0x90 && value == 0) {
            let Some(start) = starts.get_mut(&id).and_then(VecDeque::pop_front) else {
                return Vec::new();
            };
            // Preserve the release margin and final pre-note controller target.
            active.push((start, tick.saturating_add(ppq * 2)));
        }
    }
    if active.is_empty() || starts.values().any(|v| !v.is_empty()) {
        return Vec::new();
    }
    active.sort_unstable();
    let mut merged: Vec<(i64, i64)> = Vec::new();
    for (a, b) in active {
        if let Some(last) = merged.last_mut().filter(|last| a <= last.1) {
            last.1 = last.1.max(b);
        } else {
            merged.push((a, b));
        }
    }
    let start = events.first().map_or(0, |e| e.0);
    let end = events.last().map_or(0, |e| e.0);
    let mut quiet = Vec::new();
    let mut cursor = start;
    for (a, b) in merged {
        if a > cursor {
            quiet.push((cursor, a));
        }
        cursor = cursor.max(b);
    }
    if cursor < end {
        quiet.push((cursor, end));
    }
    quiet
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn protects_overlapping_notes_and_release_margins() {
        let e = [
            (0, 0xb0, 11, 0),
            (960, 0x90, 60, 100),
            (1000, 0x90, 64, 100),
            (1200, 0x80, 60, 0),
            (1500, 0x80, 64, 0),
            (5000, 0xb0, 11, 0),
        ];
        assert_eq!(quiet_regions(&e, 960), vec![(0, 960), (3420, 5000)]);
    }
    #[test]
    fn avoids_guessing_silence_on_controller_tracks_or_with_sustain() {
        assert!(quiet_regions(&[(0, 0xb0, 11, 0), (1000, 0xb0, 11, 127)], 960).is_empty());
        assert!(quiet_regions(
            &[(0, 0x90, 60, 100), (100, 0xb0, 64, 127), (200, 0x80, 60, 0)],
            960
        )
        .is_empty());
        assert!(quiet_regions(&[(0, 0x90, 60, 100)], 960).is_empty());
    }
}
