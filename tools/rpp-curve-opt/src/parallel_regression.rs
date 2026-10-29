//! Byte-for-byte serial/parallel equivalence, including complete statistics.
use crate::{native, rpp};
use std::collections::BTreeSet;

fn source(index: usize) -> String {
    let mut result = format!(
        "<SOURCE MIDI\nHASDATA 1 960 QN\nPOOLEDEVTS {{{}}}\nE 0 90 3c 64\n",
        index % 2
    );
    for tick in 0..100 {
        let value = if tick < 50 { 20 + tick } else { 120 - tick };
        result.push_str(&format!("E 10 b0 0b {value:02x}\nENV 1 0 0\n"));
    }
    result.push_str("E 10 b0 01 45\nE 10 80 3c 00\n>\n");
    result
}

fn project() -> String {
    let mut result = String::from("<REAPER_PROJECT 0.1\n");
    for index in 0..24 {
        result.push_str(&format!(
            "<TRACK\nNAME Track{index}\n<ITEM\n{}>\n>\n",
            source(index)
        ));
    }
    // A source embedded in a snapshot is never submitted for optimization.
    result.push_str(&format!(
        "<EXTENSIONS\n<SWSSNAPSHOT \"Mix\"\n{}>\n>\n>\n",
        source(0)
    ));
    result
}

#[test]
fn rpp_serial_and_parallel_are_byte_identical_with_identical_stats() {
    let input = project();
    let ccs = BTreeSet::from([11]);
    for remove_snapshots in [false, true] {
        for gestures in [false, true] {
            let run = |threads| {
                rpp::transform(
                    &input,
                    &ccs,
                    4.,
                    rpp::TransformOptions {
                        remove_snapshots,
                        de_jitter: true,
                        gestures,
                        threads,
                        ..Default::default()
                    },
                )
                .unwrap()
            };
            let serial = run(1);
            assert_eq!(serial, run(4));
            assert_eq!(serial, run(8));
            assert_eq!(serial.1.sources, 24);
            assert_eq!(serial.1.snapshots, usize::from(remove_snapshots));
        }
    }
}

fn batch(sources: &[Vec<u8>]) -> Vec<u8> {
    let mut result = b"GCC1".to_vec();
    result.extend((sources.len() as u32).to_le_bytes());
    for source in sources {
        result.extend(960_u32.to_le_bytes());
        result.extend((source.len() as u64).to_le_bytes());
        result.extend(source);
    }
    result
}
fn event(data: &mut Vec<u8>, delta: i32, flags: u8, message: &[u8]) {
    data.extend(delta.to_le_bytes());
    data.push(flags);
    data.extend((message.len() as u32).to_le_bytes());
    data.extend(message);
}

#[test]
fn native_serial_and_parallel_are_byte_identical_with_identical_stats() {
    let mut sources = Vec::new();
    for index in 0..24 {
        let mut raw = Vec::new();
        event(&mut raw, 0, 0, &[0x90, 60 + index, 100]);
        for tick in 0..100 {
            let value = if tick < 50 { 20 + tick } else { 120 - tick };
            event(&mut raw, 10, 0x10, &[0xb0, 11, value]);
        }
        event(&mut raw, 10, 1, &[0xb0, 1, 69]);
        event(&mut raw, 10, 2, &[0x80, 60 + index, 0]);
        event(&mut raw, 0, 0, &[]);
        sources.push(raw);
    }
    let input = batch(&sources);
    for gestures in [false, true] {
        let run =
            |threads| native::batch(&input, &[11].into(), 4., true, gestures, threads).unwrap();
        let serial = run(1);
        assert_eq!(serial, run(4));
        assert_eq!(serial, run(8));
        assert_eq!(serial.1.sources, 24);
    }
}

#[test]
fn native_container_is_validated_before_workers_and_errors_keep_source_order() {
    let mut unsorted = Vec::new();
    event(&mut unsorted, -1, 0, &[0xb0, 11, 20]);
    let mut input = batch(&[vec![0], unsorted]);
    for threads in [1, 4, 8] {
        assert_eq!(
            native::batch(&input, &[11].into(), 4., true, true, threads).unwrap_err(),
            "Truncated native MIDI header"
        );
    }
    input.push(0);
    assert_eq!(
        native::batch(&input, &[11].into(), 4., true, true, 8).unwrap_err(),
        "Trailing MIDI batch data"
    );
}
