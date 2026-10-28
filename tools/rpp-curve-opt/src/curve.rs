//! Native curve fitting. The reference is the contour joining recorded values,
//! rather than the staircase between recorded MIDI messages.
const TABLE: &[u8] = include_bytes!("../data/bezier.f32le");
const SAMPLES: usize = 1025;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Model {
    pub shape: u8,
    pub tension: f64,
}
pub const LINEAR: Model = Model {
    shape: 1,
    tension: 0.0,
};

impl Model {
    pub fn value(self, x: f64) -> f64 {
        let x = x.clamp(0.0, 1.0);
        match self.shape {
            0 => {
                if x < 1.0 {
                    0.0
                } else {
                    1.0
                }
            }
            1 => x,
            2 => x * x * (3.0 - 2.0 * x),
            3 => 1.0 - (1.0 - x).powi(3),
            4 => x.powi(3),
            5 => {
                let row = ((self.tension + 1.0) * 20.0).round() as usize;
                let pos = x * (SAMPLES - 1) as f64;
                let i = (pos.floor() as usize).min(SAMPLES - 2);
                let read = |j: usize| {
                    let p = (row * SAMPLES + j) * 4;
                    f32::from_le_bytes(TABLE[p..p + 4].try_into().unwrap()) as f64
                };
                read(i) + (read(i + 1) - read(i)) * (pos - i as f64)
            }
            _ => unreachable!(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Point {
    pub tick: i64,
    pub value: f64,
    pub shaped: bool,
    pub muted: bool,
    pub repaired_fade: bool,
}

#[derive(Clone, Debug)]
pub struct Segment {
    pub first: usize,
    pub last: usize,
    /// None means preserve the original outgoing curve, including square holds.
    pub model: Option<Model>,
    pub error: f64,
}

pub(crate) fn error(
    points: &[Point],
    a: usize,
    b: usize,
    model: Model,
    stride: usize,
) -> (f64, usize) {
    let dt = (points[b].tick - points[a].tick) as f64;
    let dv = points[b].value - points[a].value;
    let mut worst = (0.0, (a + b) / 2);
    let mut check = |tick: f64, value: f64, split: usize| {
        let x = (tick - points[a].tick as f64) / dt;
        let e = (points[a].value + dv * model.value(x) - value).abs();
        if e > worst.0 {
            worst = (e, split.clamp(a + 1, b - 1));
        }
    };
    for j in (a + 1..b).step_by(stride) {
        check(points[j].tick as f64, points[j].value, j);
    }
    // Also constrain between samples, so a curved fit cannot wander through gaps.
    for j in (a..b).step_by(stride) {
        let next = (j + 1).min(b);
        for f in [0.25, 0.5, 0.75] {
            let tick = points[j].tick as f64 + (points[next].tick - points[j].tick) as f64 * f;
            let value = points[j].value + (points[next].value - points[j].value) * f;
            check(tick, value, if f < 0.5 { j } else { next });
        }
    }
    worst
}

pub(crate) fn fit(points: &[Point], a: usize, b: usize, tolerance: f64) -> (Model, f64, usize) {
    if b == a + 1 {
        return (LINEAR, 0.0, a);
    }
    let (linear_error, linear_split) = error(points, a, b, LINEAR, 1);
    if linear_error <= tolerance {
        return (LINEAR, linear_error, linear_split);
    }
    let stride = ((b - a) / 64).max(1);
    let mut best = (LINEAR, linear_error, linear_split);
    for shape in 2..=5 {
        let tensions: Vec<f64> = if shape == 5 {
            (-20..=20).map(|i| i as f64 / 20.0).collect()
        } else {
            vec![0.0]
        };
        for tension in tensions {
            let model = Model { shape, tension };
            let sample = error(points, a, b, model, stride);
            if sample.0 < best.1 {
                let full = if stride == 1 {
                    sample
                } else {
                    error(points, a, b, model, 1)
                };
                if full.0 < best.1 {
                    best = (model, full.0, full.1);
                }
            }
        }
    }
    best
}

pub fn optimize(points: &[Point], ppq: i64, tolerance: f64) -> Vec<Segment> {
    if points.len() < 2 {
        return Vec::new();
    }
    let mut bounds = vec![0, points.len() - 1];
    let mut protected = vec![false; points.len()];
    for (i, interval) in protected.iter_mut().enumerate().take(points.len() - 1) {
        if protected_interval(points, i, ppq, tolerance) {
            bounds.extend([i, i + 1]);
            *interval = true;
        }
    }
    bounds.sort_unstable();
    bounds.dedup();
    let mut stack: Vec<_> = bounds.windows(2).map(|w| (w[0], w[1])).collect();
    let mut segments = Vec::new();
    while let Some((a, b)) = stack.pop() {
        if protected[a] {
            assert_eq!(b, a + 1);
            segments.push(Segment {
                first: a,
                last: b,
                model: None,
                error: 0.0,
            });
            continue;
        }
        let (model, e, split) = fit(points, a, b, tolerance);
        if e <= tolerance {
            segments.push(Segment {
                first: a,
                last: b,
                model: Some(model),
                error: e,
            });
        } else {
            stack.extend([(a, split), (split, b)]);
        }
    }
    segments.sort_by_key(|s| s.first);
    // Remove avoidable split anchors left by recursive fitting.
    for _ in 0..2 {
        let mut merged = Vec::new();
        let mut i = 0;
        while i < segments.len() {
            if i + 1 < segments.len()
                && segments[i].model.is_some()
                && segments[i + 1].model.is_some()
            {
                let a = segments[i].first;
                let b = segments[i + 1].last;
                let (model, e, _) = fit(points, a, b, tolerance);
                if e <= tolerance {
                    merged.push(Segment {
                        first: a,
                        last: b,
                        model: Some(model),
                        error: e,
                    });
                    i += 2;
                    continue;
                }
            }
            merged.push(segments[i].clone());
            i += 1;
        }
        segments = merged;
    }
    straighten_continuations(points, segments, tolerance)
}

pub(crate) fn protected_interval(points: &[Point], i: usize, ppq: i64, tolerance: f64) -> bool {
    let dt = points[i + 1].tick - points[i].tick;
    let dv = (points[i + 1].value - points[i].value).abs();
    points[i].shaped
        || dt <= 0
        || points[i].muted != points[i + 1].muted
        || (dt <= ppq / 16
            && dv >= 16.0
            && !(points[i].repaired_fade && points[i + 1].repaired_fade))
        || (points[i].value == 0.0 && dt > ppq / 4)
        || (dt > ppq * 2 && dv > tolerance * 2.0)
}

// An independently fitted ease can restart almost flat at every retained anchor.
// Keep rounded turns, but replace those artificial pauses inside one direction
// with tolerance-checked linear pieces.
fn straighten_continuations(
    points: &[Point],
    segments: Vec<Segment>,
    tolerance: f64,
) -> Vec<Segment> {
    let direction = |s: &Segment| (points[s.last].value - points[s.first].value).signum();
    let mut result = Vec::new();
    for (i, segment) in segments.iter().enumerate() {
        let Some(model) = segment.model else {
            result.push(segment.clone());
            continue;
        };
        let dir = direction(segment);
        let continues =
            |other: &Segment| other.model.is_some() && dir != 0.0 && direction(other) == dir;
        let step = 1.0 / 64.0;
        let slow_start = (model.value(step) - model.value(0.0)) / step < 0.5;
        let slow_end = (model.value(1.0) - model.value(1.0 - step)) / step < 0.5;
        let restart = i > 0 && continues(&segments[i - 1]) && slow_start;
        let pause = i + 1 < segments.len() && continues(&segments[i + 1]) && slow_end;
        if !restart && !pause {
            result.push(segment.clone());
            continue;
        }
        let mut stack = vec![(segment.first, segment.last)];
        let mut pieces = Vec::new();
        while let Some((a, b)) = stack.pop() {
            let (e, split) = if b == a + 1 {
                (0.0, a)
            } else {
                error(points, a, b, LINEAR, 1)
            };
            if e <= tolerance {
                pieces.push(Segment {
                    first: a,
                    last: b,
                    model: Some(LINEAR),
                    error: e,
                });
            } else {
                // Prefer an original anchor inside the endpoint value range,
                // avoiding a small noisy reversal becoming a new visible kink.
                let low = points[a].value.min(points[b].value);
                let high = points[a].value.max(points[b].value);
                let split = (a + 1..b)
                    .filter(|&j| (low..=high).contains(&points[j].value))
                    .min_by_key(|&j| j.abs_diff(split))
                    .unwrap_or(split);
                stack.extend([(a, split), (split, b)]);
            }
        }
        pieces.sort_by_key(|s| s.first);
        result.extend(pieces);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn points(model: Model) -> Vec<Point> {
        (0..101)
            .map(|i| Point {
                tick: i * 10,
                value: 10.0 + 100.0 * model.value(i as f64 / 100.0),
                shaped: false,
                muted: false,
                repaired_fade: false,
            })
            .collect()
    }
    #[test]
    fn replaces_a_whole_s_curve_with_two_anchors() {
        let result = optimize(
            &points(Model {
                shape: 2,
                tension: 0.0,
            }),
            960,
            1.0,
        );
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].model.unwrap().shape, 2);
    }
    #[test]
    fn replaces_bezier_with_two_anchors() {
        let result = optimize(
            &points(Model {
                shape: 5,
                tension: 0.45,
            }),
            960,
            0.05,
        );
        assert_eq!(result.len(), 1);
        assert_eq!(result[0].model.unwrap().shape, 5);
    }
    #[test]
    fn rising_continuations_do_not_restart_with_an_ease() {
        let mut p = points(Model {
            shape: 4,
            tension: 0.0,
        });
        let mut next = p.clone();
        for point in &mut next {
            point.tick += 1000;
            point.value += 100.0;
        }
        p.extend(next.into_iter().skip(1));
        let segments = (0..2)
            .map(|i| Segment {
                first: i * 100,
                last: (i + 1) * 100,
                model: Some(Model {
                    shape: 4,
                    tension: 0.0,
                }),
                error: 0.0,
            })
            .collect();
        let fitted = straighten_continuations(&p, segments, 2.0);
        assert_eq!(fitted[0].model.unwrap().shape, 4); // initial fade keeps its curve
        assert!(fitted.iter().skip(1).all(|s| s.model == Some(LINEAR)));
        assert!(fitted.iter().all(|s| s.error <= 2.0));
    }
    #[test]
    fn a_rounded_direction_change_keeps_its_curves() {
        let mut p = points(Model {
            shape: 2,
            tension: 0.0,
        });
        for point in &mut p {
            point.value = 120.0 - point.value;
        }
        let mut rise = points(Model {
            shape: 2,
            tension: 0.0,
        });
        for point in &mut rise {
            point.tick += 1000;
        }
        p.extend(rise.into_iter().skip(1));
        let segments = (0..2)
            .map(|i| Segment {
                first: i * 100,
                last: (i + 1) * 100,
                model: Some(Model {
                    shape: 2,
                    tension: 0.0,
                }),
                error: 0.0,
            })
            .collect();
        let fitted = straighten_continuations(&p, segments, 2.0);
        assert_eq!(fitted.len(), 2);
        assert!(fitted.iter().all(|s| s.model.unwrap().shape == 2));
    }
    #[test]
    fn protects_reset_and_existing_curve() {
        let p = vec![
            Point {
                tick: 0,
                value: 90.,
                shaped: false,
                muted: false,
                repaired_fade: false,
            },
            Point {
                tick: 1,
                value: 0.,
                shaped: true,
                muted: false,
                repaired_fade: false,
            },
            Point {
                tick: 960,
                value: 127.,
                shaped: false,
                muted: false,
                repaired_fade: false,
            },
        ];
        let r = optimize(&p, 960, 2.0);
        assert_eq!(r.len(), 2);
        assert!(r.iter().all(|s| s.model.is_none()));
    }
}
