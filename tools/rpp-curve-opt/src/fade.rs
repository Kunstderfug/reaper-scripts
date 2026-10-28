//! Repair short interleaved fade branches adjoining the zero-expression floor.
use crate::curve::Point;
use std::collections::BTreeSet;

#[derive(Default)]
pub struct Repair {
    pub removed: BTreeSet<usize>,
    pub smooth: BTreeSet<usize>,
    pub deviation: f64,
}

pub fn repair(points: &[Point], ppq: i64) -> Repair {
    let mut result = Repair::default();
    mark_monotonic_fades(points, ppq, &mut result.smooth);
    let tight = (ppq / 120).max(1);
    let pairs: Vec<_> = points
        .windows(2)
        .enumerate()
        .filter_map(|(i, p)| {
            let dt = p[1].tick - p[0].tick;
            let dv = (p[1].value - p[0].value).abs();
            (dt >= 0
                && dt <= tight
                && (3.0..=64.0).contains(&dv)
                && !p[0].shaped
                && !p[1].shaped
                && p[0].muted == p[1].muted)
                .then_some(i)
        })
        .collect();
    let mut first = 0;
    while first < pairs.len() {
        let mut last = first;
        while last + 1 < pairs.len()
            && points[pairs[last + 1]].tick - points[pairs[last]].tick <= ppq / 8
            && points[pairs[last + 1] + 1].tick - points[pairs[first]].tick <= ppq / 4
        {
            last += 1;
        }
        if last > first {
            let a = pairs[first].saturating_sub(1);
            let b = (pairs[last] + 2).min(points.len() - 1);
            let duration = points[b].tick - points[a].tick;
            let delta = points[b].value - points[a].value;
            let direction = delta.signum();
            if duration > 0
                && duration <= ppq / 4
                && delta.abs() >= 12.0
                && points[a].value.min(points[b].value) <= 2.0
                && points[a..=b]
                    .iter()
                    .all(|p| !p.shaped && p.muted == points[a].muted)
                && pairs[first..=last]
                    .iter()
                    .all(|&i| (points[i + 1].value - points[i].value) * direction < 0.0)
            {
                let mut value = points[a].value;
                let mut kept = vec![a];
                for (i, p) in points.iter().enumerate().take(b).skip(a + 1) {
                    if (p.value - value) * direction < 0.0
                        || (points[b].value - p.value) * direction < 0.0
                    {
                        result.removed.insert(i);
                    } else {
                        value = p.value;
                        kept.push(i);
                    }
                }
                kept.push(b);
                for edges in kept.windows(2) {
                    let (left, right) = (edges[0], edges[1]);
                    let dt = points[right].tick - points[left].tick;
                    if dt > 0 {
                        for p in &points[left + 1..right] {
                            let x = (p.tick - points[left].tick) as f64 / dt as f64;
                            let y =
                                points[left].value + x * (points[right].value - points[left].value);
                            result.deviation = result.deviation.max((p.value - y).abs());
                        }
                    }
                }
                result.smooth.extend(a..=b);
            }
        }
        first = last + 1;
    }
    result
}

// A large step inside a densely recorded, consistently directed fade is a ramp
// sample, rather than an isolated controller reset. Permit interpolation there.
fn mark_monotonic_fades(points: &[Point], ppq: i64, smooth: &mut BTreeSet<usize>) {
    let mut start = 0;
    while start + 1 < points.len() {
        let mut end = start;
        let mut direction = 0.0;
        while end + 1 < points.len() {
            let a = points[end];
            let b = points[end + 1];
            let dt = b.tick - a.tick;
            let change = (b.value - a.value).signum();
            if dt <= 0
                || dt > ppq / 8
                || a.shaped
                || b.shaped
                || a.muted != b.muted
                || (direction != 0.0 && change != 0.0 && change != direction)
            {
                break;
            }
            if change != 0.0 {
                direction = change;
            }
            end += 1;
        }
        if end >= start + 3
            && points[end].tick - points[start].tick <= ppq * 2
            && (points[end].value - points[start].value).abs() >= 16.0
            && points[start].value.min(points[end].value) <= 2.0
        {
            smooth.extend(start..=end);
        }
        start = if end > start { end } else { start + 1 };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn points(raw: &[(i64, f64)]) -> Vec<Point> {
        raw.iter()
            .map(|&(tick, value)| Point {
                tick,
                value,
                shaped: false,
                muted: false,
                repaired_fade: false,
            })
            .collect()
    }
    #[test]
    fn removes_the_recorded_fade_out_returns_to_high_values() {
        let p = points(&[
            (62427, 26.),
            (62447, 21.),
            (62451, 27.),
            (62471, 16.),
            (62475, 28.),
            (62495, 9.),
            (62499, 26.),
            (62519, 3.),
            (62523, 25.),
            (62543, 0.),
        ]);
        let r = repair(&p, 960);
        assert_eq!(r.removed, [2, 4, 6, 8].into());
        assert!(!r.removed.contains(&9));
    }
    #[test]
    fn removes_the_recorded_fade_in_returns_to_low_values() {
        let p = points(&[
            (63461, 1.),
            (63479, 31.),
            (63484, 9.),
            (63503, 40.),
            (63507, 19.),
            (63527, 46.),
        ]);
        let r = repair(&p, 960);
        assert_eq!(r.removed, [2, 4].into());
        let cleaned: Vec<_> = p
            .iter()
            .enumerate()
            .filter(|(i, _)| !r.removed.contains(i))
            .map(|(_, p)| Point {
                repaired_fade: true,
                ..*p
            })
            .collect();
        let segments = crate::curve::optimize(&cleaned, 960, 2.0);
        assert!(segments.iter().all(|s| s.model.is_some()));
    }
    #[test]
    fn preserves_an_isolated_reset() {
        let p = points(&[(0, 0.), (1, 127.), (960, 127.)]);
        assert!(repair(&p, 960).removed.is_empty());
        assert!(repair(&p, 960).smooth.is_empty());
    }
    #[test]
    fn interpolates_the_large_sample_inside_the_recorded_rising_fade() {
        let p = points(&[
            (81962, 1.),
            (81985, 12.),
            (82009, 29.),
            (82034, 43.),
            (82057, 54.),
            (82081, 65.),
            (82105, 73.),
            (82129, 79.),
            (82153, 85.),
            (82177, 91.),
            (82201, 95.),
            (82225, 98.),
        ]);
        let r = repair(&p, 960);
        assert!(r.removed.is_empty());
        let cleaned: Vec<_> = p
            .iter()
            .enumerate()
            .map(|(i, p)| Point {
                repaired_fade: r.smooth.contains(&i),
                ..*p
            })
            .collect();
        let segments = crate::curve::optimize(&cleaned, 960, 2.0);
        assert!(segments.iter().all(|s| s.model.is_some()));
    }
    #[test]
    fn keeps_silence_between_continuous_fades() {
        let mut p = points(&[
            (62427, 26.),
            (62543, 0.),
            (63461, 1.),
            (63479, 31.),
            (63503, 40.),
            (63527, 46.),
        ]);
        for point in &mut p {
            point.repaired_fade = true;
        }
        let segments = crate::curve::optimize(&p, 960, 2.0);
        let hold = segments.iter().find(|s| s.first == 1).unwrap();
        assert_eq!(hold.last, 2);
        assert!(hold.model.is_none());
        assert!(segments
            .iter()
            .filter(|s| s.first != 1)
            .all(|s| s.model.is_some()));
    }
}
