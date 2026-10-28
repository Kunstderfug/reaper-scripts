//! Fit complete gestures, preserving significant turns at their original ticks.
use crate::curve::{self, Model, Point, Segment, LINEAR};
use std::collections::BTreeSet;

pub fn optimize(points: &[Point], ppq: i64, tolerance: f64) -> Vec<Segment> {
    with_quiet_regions(points, ppq, tolerance, &[])
}

pub fn with_quiet_regions(
    points: &[Point],
    ppq: i64,
    tolerance: f64,
    quiet: &[(i64, i64)],
) -> Vec<Segment> {
    if points.len() < 2 {
        return Vec::new();
    }
    let mut bounds: BTreeSet<usize> = [0, points.len() - 1].into();
    let is_quiet = |a: usize, b: usize| {
        quiet
            .iter()
            .any(|&(start, end)| points[a].tick >= start && points[b].tick <= end)
    };
    let protected = |i: usize| {
        let structural = points[i].shaped
            || points[i].muted != points[i + 1].muted
            || points[i + 1].tick <= points[i].tick;
        structural || (!is_quiet(i, i + 1) && curve::protected_interval(points, i, ppq, tolerance))
    };
    for &(start, end) in quiet {
        let a = points.partition_point(|p| p.tick < start);
        let b = points.partition_point(|p| p.tick <= end);
        if b > a + 1 {
            bounds.extend([a, b - 1]);
        }
    }
    for i in 0..points.len() - 1 {
        if protected(i) {
            bounds.extend([i, i + 1]);
        }
    }
    let bounds: Vec<_> = bounds.into_iter().collect();
    let mut result = Vec::new();
    for w in bounds.windows(2) {
        let (a, b) = (w[0], w[1]);
        if protected(a) {
            result.push(Segment {
                first: a,
                last: b,
                model: None,
                error: 0.0,
            });
            continue;
        }
        if is_quiet(a, b) {
            // The exact initial and final controller states matter here; the
            // intermediate contour is intentionally discarded outside notes.
            let (model, e, _) = curve::fit(points, a, b, tolerance);
            result.push(Segment {
                first: a,
                last: b,
                model: Some(model),
                error: e,
            });
            continue;
        }
        let turns = turns(points, a, b, (tolerance * 2.0).max(6.0));
        for t in turns.windows(2) {
            result.extend(fit_gesture(points, t[0], t[1], tolerance));
        }
    }
    result
}

fn turns(p: &[Point], a: usize, b: usize, threshold: f64) -> Vec<usize> {
    let mut result = vec![a];
    let (mut low, mut high, mut direction) = (a, a, 0);
    for i in a + 1..=b {
        if direction == 0 {
            if p[i].value < p[low].value {
                low = i;
            }
            if p[i].value > p[high].value {
                high = i;
            }
            if p[i].value - p[low].value >= threshold {
                if low > a {
                    result.push(low);
                }
                direction = 1;
                high = i;
            } else if p[high].value - p[i].value >= threshold {
                if high > a {
                    result.push(high);
                }
                direction = -1;
                low = i;
            }
        } else if direction > 0 {
            if p[i].value > p[high].value {
                high = i;
            }
            if p[high].value - p[i].value >= threshold {
                result.push(high);
                direction = -1;
                low = i;
            }
        } else {
            if p[i].value < p[low].value {
                low = i;
            }
            if p[i].value - p[low].value >= threshold {
                result.push(low);
                direction = 1;
                high = i;
            }
        }
    }
    result.push(b);
    result.dedup();
    result
}

fn fit_gesture(p: &[Point], a: usize, b: usize, tolerance: f64) -> Vec<Segment> {
    let (model, e, _) = curve::fit(p, a, b, tolerance);
    if e <= tolerance {
        return vec![Segment {
            first: a,
            last: b,
            model: Some(model),
            error: e,
        }];
    }
    // Include a valid linear fallback path, plus evenly spaced original anchors.
    // The shortest path minimizes segments over this bounded candidate set.
    let mut nodes: BTreeSet<usize> = [a, b].into();
    let mut stack = vec![(a, b)];
    while let Some((left, right)) = stack.pop() {
        if right == left + 1 {
            continue;
        }
        let (e, split) = curve::error(p, left, right, LINEAR, 1);
        if e > tolerance {
            nodes.insert(split);
            stack.extend([(left, split), (split, right)]);
        }
    }
    for i in 1..32 {
        nodes.insert(a + (b - a) * i / 32);
    }
    let nodes: Vec<_> = nodes.into_iter().collect();
    let mut cost = vec![(usize::MAX, usize::MAX, f64::INFINITY); nodes.len()];
    let mut previous = vec![None; nodes.len()];
    cost[0] = (0, 0, 0.0);
    for j in 1..nodes.len() {
        for i in 0..j {
            let (left, right) = (nodes[i], nodes[j]);
            let mut models = vec![LINEAR];
            if i == 0 || j == nodes.len() - 1 {
                models.extend((2..=4).map(|shape| Model {
                    shape,
                    tension: 0.0,
                }));
                models.extend((-20..=20).map(|t| Model {
                    shape: 5,
                    tension: t as f64 / 20.0,
                }));
            }
            for model in models {
                let step = 1.0 / 64.0;
                if i > 0 && (model.value(step) - model.value(0.0)) / step < 0.5 {
                    continue;
                }
                if j < nodes.len() - 1 && (model.value(1.0) - model.value(1.0 - step)) / step < 0.5
                {
                    continue;
                }
                let e = if right == left + 1 && model == LINEAR {
                    0.0
                } else if right == left + 1 {
                    continue;
                } else {
                    curve::error(p, left, right, model, 1).0
                };
                if e > tolerance || cost[i].0 == usize::MAX {
                    continue;
                }
                let candidate = (
                    cost[i].0 + 1,
                    cost[i].1 + usize::from(model != LINEAR),
                    cost[i].2 + e,
                );
                if candidate < cost[j] {
                    cost[j] = candidate;
                    previous[j] = Some((i, model, e));
                }
            }
        }
    }
    let mut result = Vec::new();
    let mut j = nodes.len() - 1;
    while j > 0 {
        let (i, model, e) = previous[j].expect("linear fallback path must exist");
        result.push(Segment {
            first: nodes[i],
            last: nodes[j],
            model: Some(model),
            error: e,
        });
        j = i;
    }
    result.reverse();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn p(tick: i64, value: f64) -> Point {
        Point {
            tick,
            value,
            shaped: false,
            muted: false,
            repaired_fade: true,
        }
    }
    #[test]
    fn noisy_linear_gesture_becomes_two_anchors() {
        let points: Vec<_> = (0..101)
            .map(|i| p(i * 10, 10.0 + i as f64 + if i % 2 == 0 { 0.0 } else { 1.0 }))
            .collect();
        let r = optimize(&points, 960, 4.0);
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].model, Some(LINEAR));
    }
    #[test]
    fn pre_note_setup_keeps_only_exact_start_and_target() {
        let points = vec![
            p(0, 0.),
            p(500, 0.),
            p(600, 20.),
            p(700, 15.),
            p(800, 70.),
            p(900, 90.),
            p(1000, 100.),
            p(1100, 100.),
            p(1200, 100.),
        ];
        let result = with_quiet_regions(&points, 960, 4.0, &[(0, 950)]);
        assert_eq!(result[0].first, 0);
        assert_eq!(result[0].last, 5); // last original controller before note-on
        assert!(result[0].model.is_some());
        assert!(result[0].error > 4.0); // intentional removal of inaudible detail
        assert!(result.iter().skip(1).all(|s| s.error <= 4.0));
    }
    #[test]
    fn preserves_peak_and_valley_ticks() {
        let points = vec![
            p(0, 20.),
            p(100, 60.),
            p(200, 100.),
            p(300, 60.),
            p(400, 20.),
            p(500, 60.),
        ];
        let r = optimize(&points, 960, 4.0);
        assert_eq!(r.len(), 3);
        assert_eq!(r[0].last, 2);
        assert_eq!(r[1].last, 4);
        assert!(r.iter().all(|s| s.model.is_some()));
    }
    #[test]
    fn keeps_zero_hold_before_a_fade() {
        let points = vec![
            p(0, 0.),
            p(960, 1.),
            p(984, 20.),
            p(1008, 40.),
            p(1032, 60.),
        ];
        let r = optimize(&points, 960, 4.0);
        assert!(r[0].model.is_none());
        assert_eq!(r[0].last, 1);
        assert!(r.iter().skip(1).all(|s| s.model.is_some()));
    }
    #[test]
    fn retains_a_real_pause_inside_a_rising_gesture() {
        let points: Vec<_> = (0..=30)
            .map(|i| {
                let value = if i <= 10 {
                    10.0 + 5.0 * i as f64
                } else if i <= 20 {
                    60.0
                } else {
                    60.0 + 5.0 * (i - 20) as f64
                };
                p(i * 100, value)
            })
            .collect();
        let result = optimize(&points, 960, 4.0);
        assert!(result.len() >= 3);
        for segment in &result {
            let model = segment.model.unwrap();
            if segment.last > segment.first + 1 {
                assert!(curve::error(&points, segment.first, segment.last, model, 1).0 <= 4.0);
            }
        }
        assert!(result.iter().any(|s| points[s.first].tick <= 1500
            && points[s.last].tick >= 1500
            && (points[s.first].value - 60.0).abs() <= 4.0
            && (points[s.last].value - 60.0).abs() <= 4.0));
    }
}
