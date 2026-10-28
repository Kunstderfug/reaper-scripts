mod activity;
mod curve;
mod fade;
mod gesture;
mod jitter;
mod native;
mod rpp;
use std::{collections::BTreeSet, env, fs, io::Write, path::PathBuf};

fn run() -> Result<(), String> {
    let args: Vec<_> = env::args().skip(1).collect();
    if args.len() < 2 {
        return Err("Usage: rpp-curve-opt INPUT.RPP OUTPUT.RPP [--track EXACT_NAME] [--cc 1,3,11,13,22] [--tolerance 2] [--de-jitter] [--gestures] [--snapshots-only] [--keep-snapshots]".into());
    }
    let input = PathBuf::from(&args[0]);
    let output = PathBuf::from(&args[1]);
    if output.exists() {
        return Err("Output already exists; choose a new filename".into());
    }
    let mut ccs: BTreeSet<u8> = [1, 3, 11, 13, 22].into();
    let mut tolerance = 2.0_f64;
    let mut track = None;
    let mut remove_snapshots = true;
    let mut snapshots_only = false;
    let mut de_jitter = false;
    let mut gestures = false;
    let mut native_batch = false;
    let mut i = 2;
    while i < args.len() {
        let key = args[i].as_str();
        match key {
            "--snapshots-only" => snapshots_only = true,
            "--keep-snapshots" => remove_snapshots = false,
            "--de-jitter" => de_jitter = true,
            "--gestures" => gestures = true,
            "--native-batch" => native_batch = true,
            "--track" | "--cc" | "--tolerance" => {
                i += 1;
                let value = args.get(i).ok_or(format!("Missing value for {key}"))?;
                match key {
                    "--track" => track = Some(value.as_str()),
                    "--cc" => {
                        ccs = if value == "continuous" {
                            (1..120)
                                .filter(|c| {
                                    *c != 6 && !(32..=69).contains(c) && !(96..=101).contains(c)
                                })
                                .collect()
                        } else {
                            value
                                .split(',')
                                .map(|s| {
                                    s.parse::<u8>()
                                        .map_err(|_| "Invalid controller list".to_string())
                                })
                                .collect::<Result<_, _>>()?
                        };
                        if ccs.is_empty() || ccs.iter().any(|&c| c >= 128) {
                            return Err("CCs must be 0..127".into());
                        }
                    }
                    _ => tolerance = value.parse().map_err(|_| "Invalid tolerance")?,
                }
            }
            _ => return Err(format!("Unknown option: {key}")),
        }
        i += 1;
    }
    if !tolerance.is_finite() || tolerance <= 0.0 || tolerance > 16.0 {
        return Err("Tolerance must be >0 and <=16".into());
    }
    if snapshots_only {
        ccs.clear();
    }
    let data = fs::read(&input).map_err(|e| e.to_string())?;
    let (result, stats) = if native_batch {
        native::batch(&data, &ccs, tolerance, de_jitter, gestures)?
    } else {
        let text = std::str::from_utf8(&data).map_err(|_| "RPP is not UTF-8")?;
        let (result, stats) = rpp::transform(
            text,
            &ccs,
            tolerance,
            track,
            remove_snapshots,
            de_jitter,
            gestures,
        )?;
        rpp::blocks(&result)?;
        (result.into_bytes(), stats)
    };
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&output)
        .map_err(|e| e.to_string())?;
    file.write_all(&result).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    println!(
        "Output: {}\nSize: {} -> {} bytes ({:.2}% smaller)",
        output.display(),
        data.len(),
        result.len(),
        100.0 * (1.0 - result.len() as f64 / data.len() as f64)
    );
    println!(
        "Track: {}\nProcessed MIDI sources: {}\nSnapshots removed: {} ({} bytes)",
        track.unwrap_or("all"),
        stats.sources,
        stats.snapshots,
        stats.snapshot_bytes
    );
    println!(
        "Fit mode: {} (tolerance {tolerance})",
        if gestures {
            "whole gestures"
        } else {
            "recorded contour"
        }
    );
    for (cc, before) in &stats.before {
        println!("CC{cc}: {before} -> {} anchors", stats.after[cc]);
    }
    println!("Native segment shapes: {:?}\nMaximum contour error: {:.6} MIDI values\nUnsupported text/SysEx sources left unchanged: {}", stats.shapes, stats.max_error, stats.unsupported);
    println!("Jitter points removed before fitting: {}\nMaximum local jitter replacement deviation: {:.6} MIDI values",stats.jitter_removed,stats.jitter_deviation);
    if gestures {
        println!(
            "Maximum note-free simplification deviation (outside fitting limit): {:.6} MIDI values",
            stats.quiet_error
        );
    }
    println!(
        "Collided fade branch points removed: {}\nMaximum fade repair deviation: {:.6} MIDI values",
        stats.fade_removed, stats.fade_deviation
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
