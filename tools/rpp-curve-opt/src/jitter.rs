//! Optional removal of small alternating collision clusters, before curve fitting.
//! Surviving anchor values and times are never changed.
use crate::curve::Point;
use std::collections::BTreeSet;

pub fn detect(points: &[Point], ppq: i64) -> (BTreeSet<usize>, f64) {
    let mut removed = BTreeSet::new();
    let mut max_deviation: f64 = 0.0;
    let tight = (ppq / 120).max(1);
    let pairs: Vec<_> = points
        .windows(2)
        .enumerate()
        .filter_map(|(i, p)| {
            let dt = p[1].tick - p[0].tick;
            let dv = (p[1].value - p[0].value).abs();
            (dt >= 0
                && dt <= tight
                && dv > 0.0
                && dv <= 10.0
                && !p[0].shaped
                && !p[1].shaped
                && p[0].muted == p[1].muted)
                .then_some(i)
        })
        .collect();
    let mut start = 0;
    while start < pairs.len() {
        let mut end = start;
        while end + 1 < pairs.len()
            && points[pairs[end + 1]].tick - points[pairs[end]].tick <= ppq / 8
            && points[pairs[end + 1] + 1].tick - points[pairs[start]].tick <= ppq / 4
        {
            end += 1;
        }
        if end > start {
            let a = pairs[start].saturating_sub(3);
            let b = (pairs[end] + 3).min(points.len() - 1);
            let span = &points[a..=b];
            let duration = points[b].tick - points[a].tick;
            let mut reversals = 0;
            let mut direction = 0;
            for p in span.windows(2) {
                let d = (p[1].value - p[0].value).signum() as i8;
                if d != 0 {
                    if direction != 0 && direction != d {
                        reversals += 1;
                    }
                    direction = d;
                }
            }
            if duration > 0
                && duration <= ppq / 4
                && reversals >= 3
                && span.iter().all(|p| !p.shaped && p.muted == span[0].muted)
            {
                let deviation = span
                    .iter()
                    .map(|p| {
                        let x = (p.tick - points[a].tick) as f64 / duration as f64;
                        (p.value - (points[a].value + x * (points[b].value - points[a].value)))
                            .abs()
                    })
                    .fold(0.0, f64::max);
                // Never create overlapping independent replacements: their combined
                // deviation would no longer be bounded by the local measurement.
                if deviation <= 8.0 && !(a..=b).any(|i| removed.contains(&i)) {
                    removed.extend(a + 1..b);
                    max_deviation = max_deviation.max(deviation);
                }
            }
        }
        start = end + 1;
    }
    (removed, max_deviation)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn point(tick: i64, value: f64) -> Point {
        Point {
            tick,
            value,
            shaped: false,
            muted: false,
            repaired_fade: false,
        }
    }
    #[test]
    fn collapses_small_colliding_zigzag_to_endpoints() {
        let raw = [
            (600, 86.),
            (624, 88.),
            (640, 84.),
            (670, 89.),
            (672, 83.),
            (693, 88.),
            (694, 82.),
            (717, 86.),
            (718, 83.),
            (742, 84.),
            (766, 83.),
        ];
        let p: Vec<_> = raw.into_iter().map(|(t, v)| point(t, v)).collect();
        let (removed, error) = detect(&p, 960);
        assert_eq!(removed.len(), 9);
        assert!(error <= 6.0);
        assert!(!removed.contains(&0));
        assert!(!removed.contains(&10));
    }
    #[test]
    fn retains_expressive_swell_without_collisions() {
        let p: Vec<_> = (0..20)
            .map(|i| point(i * 24, 80. + 5. * (i as f64).sin()))
            .collect();
        assert!(detect(&p, 960).0.is_empty());
    }
    #[test]
    fn removes_small_bumps_on_a_large_decline() {
        let raw = [
            (600, 100.),
            (624, 96.),
            (640, 92.),
            (670, 87.),
            (672, 90.),
            (693, 82.),
            (694, 85.),
            (717, 77.),
            (718, 80.),
            (742, 72.),
            (766, 68.),
        ];
        let p: Vec<_> = raw.into_iter().map(|(t, v)| point(t, v)).collect();
        let (removed, error) = detect(&p, 960);
        assert_eq!(removed.len(), 9);
        assert!(error <= 6.0);
    }
    #[test]
    fn removes_the_two_recorded_violin_decline_bumps() {
        let raw = [
            (79129, 80.),
            (79153, 78.),
            (79177, 74.),
            (79199, 65.),
            (79201, 70.),
            (79223, 61.),
            (79225, 67.),
            (79247, 56.),
            (79271, 51.),
            (79295, 44.),
            (79319, 36.),
        ];
        let p: Vec<_> = raw.into_iter().map(|(t, v)| point(t, v)).collect();
        let (removed, error) = detect(&p, 960);
        assert!(removed.contains(&4) && removed.contains(&6));
        assert!(error <= 8.0);
    }
    #[test]
    fn retains_large_resets_and_shaped_points() {
        let mut p: Vec<_> = (0..12)
            .map(|i| point(i * 2, if i % 2 == 0 { 0. } else { 127. }))
            .collect();
        assert!(detect(&p, 960).0.is_empty());
        for (i, p) in p.iter_mut().enumerate() {
            p.value = 80. + (i % 2) as f64 * 4.;
            p.shaped = true;
        }
        assert!(detect(&p, 960).0.is_empty());
    }
}
