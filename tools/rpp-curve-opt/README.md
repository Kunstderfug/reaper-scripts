# REAPER CC curve optimizer

Dependency-free Rust CLI that fits sparse native MIDI CC curves into a **new**
RPP file. The input is never written, and an existing output is never replaced.

```sh
cargo build --release --manifest-path tools/rpp-curve-opt/Cargo.toml
tools/rpp-curve-opt/target/release/rpp-curve-opt input.RPP trial.RPP \
  --track 'VLN 1_1_CH' --cc 11 --tolerance 2
```

`--track` matches one exact track name; omit it to process all tracks.
`--cc` selects controller lanes (default `1,3,11,13,22`). `--cc continuous` selects CC1–31 except data-entry CC6, CC70–95, and CC102–119, excluding bank/LSB, pedals, NRPN/RPN, increment/decrement, and channel-mode messages.
`--tolerance` is in MIDI controller values, default 2 out of 127.
Snapshot removal is on by default; use `--keep-snapshots` to retain them.

### Whole-gesture mode

Use `--gestures --de-jitter --tolerance 4` for the musical smoothing trial.
This preserves significant peaks/valleys at their original source ticks, using
direction-reversal hysteresis of twice the tolerance (minimum six values).
Small fluctuations do not force separate gestures. A gesture becomes two
anchors if one native curve or straight ramp fits it. Otherwise a shortest-path
search minimizes segment count over original candidate anchors: linear fallback
anchors plus 31 evenly spaced candidates. This is a bounded search, not a claim
of a global minimum over every possible curve and anchor position.

Internal pieces use straight lines; curves at gesture starts/ends must not
restart or finish almost flat at an internal join. Meaningful pauses remain
because playing-region fits are checked against the cleaned contour at original
points and quarter-interval samples. Existing curves, muted transitions and
same-tick changes remain protected; playing regions also preserve silent holds
and isolated resets. The
four-value fitting limit applies after optional collision repairs, whose larger
deviations are reported separately. Audio/performance equivalence requires
auditioning; numerical contour checks do not establish it.

With local MIDI notes present, the mode also simplifies note-free setup/gaps to
two original endpoints, retaining the exact final CC target before the next
note. Intermediate note-free detail is intentionally discarded without the
playing-region fitting limit; its deviation is reported separately. A two-quarter
note release margin is retained after every note-off. This is a MIDI-based
heuristic, not measured audio silence: long instrument tails and notes from
other items/tracks are outside its local source model. CC-only sources,
unmatched note messages, and sustain/sostenuto usage disable this relaxation.
Existing shaped intervals, same-tick events and mute boundaries remain protected.

`--de-jitter` optionally removes short alternating collision clusters before
fitting. It requires at least two close event pairs (at most 1/120 quarter note
apart), at least three direction reversals, a total span no longer than 1/4
quarter note, and no more than 10 values between each tight event pair. Cluster interiors are
removed only when the line between their original endpoints differs by at most
8 values. Shaped intervals and muted-state changes are excluded. Surviving
values/times remain original. This specifically changes small noisy contours;
it is off by default and cannot establish the historical cause of the noise.
The reported fitting tolerance applies to the cleaned contour; jitter
replacement deviation is reported separately (up to 8, plus fitting tolerance).

The same option also repairs larger interleaved fade branches near zero. It
requires at least two tight backward pairs within a short fade (at most 1/4
quarter note), a net change of at least 12 values, and an endpoint within two
values of zero. Tight pair changes are limited to 64 values. It removes backward
returns, retains a monotonic branch and the original endpoints, and allows
continuous curves through that repaired burst. Existing shaped points and mute
changes are excluded. This is an intentional contour repair: its deviation from
the removed branch can exceed eight values and is reported separately. Zero
holds longer than 1/4 quarter note remain square, preserving the silent interval.
Dense monotonic fades near zero also allow interpolation through large samples:
at least four points, gaps at most 1/8 quarter note, span at most two quarter
notes, and total change at least 16 values. This avoids misclassifying a large
sample inside a fade as an isolated reset. Such detection leaves point values
unchanged; the usual fitting tolerance still applies.

For a template or project that only needs SWS snapshots removed:

```sh
tools/rpp-curve-opt/target/release/rpp-curve-opt template.RPP clean-template.RPP \
  --snapshots-only
```

No REAPER installation or running REAPER instance is needed to use the CLI.

## Fitting behavior

Each source/controller/channel is processed separately. A whole smooth stretch
becomes two retained endpoints when a suitable curve fits. More anchors are
retained where the contour changes direction or has detail that requires them.
Candidates are linear, slow start/end, fast start, fast end, and native Bézier
with tension from -1 to +1 in 0.05 increments. Curves stay between endpoint values.

At joins continuing in the same direction, a fitted curve whose endpoint slope
falls below half its average slope is replaced with tolerance-checked linear
pieces. This prevents repeated ease restarts or pauses along a rising/falling
run. Rounded direction changes and isolated curved fades retain their curves.

The reference is the contour joining the original recorded points, **not every
edge of their MIDI staircase**. Error is tested at original points and three
intermediate positions in each original interval. This is sampled contour
matching, not a mathematical error guarantee at every possible instant and not
an audio-equivalence guarantee. Audition the result with your instruments.

Existing shaped intervals, equal-time changes, muted-state transitions, sharp
resets (16+ values within 1/16 quarter note), and long holds (over two quarter
notes followed by a change larger than twice the tolerance) remain protected.
Recognized fade repairs explicitly permit interpolation through their sharp
changes; other sharp resets remain protected.
Lanes with fewer than three points remain untouched.

Notes and unselected controllers retain their message bytes, flags, absolute
source ticks, and original curve records. Item timing, take offsets/rates,
plugins, routing, tempo maps and all data outside processed sources and removed
snapshots remain untouched. Sources containing text/SysEx are skipped and reported
rather than risking an offset change in an unsupported timed-event format.

SWS snapshots are stored recall states for track/mix settings. Removing them
removes those recall states, not the current mix. Cleaning a template prevents
those states being inherited by future projects; existing projects keep theirs.

## Native curve reference and validation

`data/bezier.f32le` contains 41 rows of 1025 little-endian float32 samples,
for tensions -1 through +1. They were measured using REAPER 7.83's
`Envelope_Evaluate` in an unscaled 0..1 envelope. The provided calibration script
can regenerate this file in REAPER (it creates a separate test project tab).
Linear and easing shapes use their exact polynomial formulas.

Native MIDI validation rendered ascending and descending CC11 segments for eight
models through a temporary MIDI-monitor JSFX. All 16 rendered curves matched the
corresponding reference to within 0.5 MIDI values, consistent with MIDI rounding.
The violin trial was also decoded by REAPER and independently checked against
the original for unchanged notes, other CC lanes, item timing and plugin state.

```sh
cargo test --manifest-path tools/rpp-curve-opt/Cargo.toml
```

API reference: [REAPER MIDI and envelope APIs](https://www.reaper.fm/sdk/reascript/reascripthelp.html).


## REAPER actions

`GPhil_optimizeProjectCC.lua` edits native MIDI buffers in place with one named
Undo/Redo transaction. Choose `items`, `tracks`, or `project`, and a space-separated
CC list (for example `11` or `1 3 11 13 22`), `auto`, or `continuous`. `auto` scans
the chosen scope and uses the sorted union of eligible continuous CC lanes
actually present. Standard bank/LSB, pedal/switch, data-entry and channel-mode
controllers are excluded under the same policy as `continuous`; detected and
excluded numbers are printed in the console. No eligible lanes means no edits
and no Undo entry. Explicit numbers override automatic lane selection.
Defaults are selected items, automatic CC detection, gesture mode, tolerance 4,
and collision repair enabled. Item/track
scopes process active MIDI takes and do not save, duplicate, or reopen the project.

Whole-project scope requires an existing filename. After preparing results, it
saves the current state (including unsaved edits) to a timestamped
`_CC_BACKUP_...RPP` beside the project. It applies changes and saves to the original
filename, verifying the project is saved and still has that name. Undo remains
available; saving after Undo updates the disk file to the undone state.

All results are computed before any MIDI is changed. Applying changes verifies
the resulting raw buffers; failures restore and verify all original buffers.
Unsorted buffers are rejected before applying. File-backed MIDI is refused.
Pooled sources are processed once when all affected takes are within scope;
pools shared outside scope (including inactive takes) are refused without
changes. With SWS installed, its MIDI pool GUID API identifies pools. Without SWS,
single-take item chunks provide pool GUIDs; multiple-take MIDI requires SWS for
safe pool inspection.

`lib/cc_scope.lua` owns scope/preflight, `lib/cc_native.lua` transports temporary
native MIDI batches, and `lib/cc_optimizer.lua` owns the transaction/backup.
The Rust `--native-batch` adapter retains original non-target messages, source
ticks, event flags, text/SysEx, and existing curve metadata. New Bezier metadata
uses REAPER's documented native CCBZ format. No item chunks, plugins, routing,
project names, item selection, or SWS snapshots are modified by MIDI processing.
The native process blocks REAPER's UI while processing; elapsed action time and
point counts are printed in the ReaScript console.

`GPhil_removeSWSSnapshots.lua` is a separate action that snapshots the latest
project state and opens a new `_NO_SWS_...RPP` copy with only saved SWS snapshots
removed. It never optimizes MIDI or overwrites the original. The CLI also retains
`--snapshots-only` and standalone RPP-copy processing.

Validation: `lua tests/cc_optimizer.lua` covers all scopes, pooled-source refusal,
preparation failure, backup failure, rollback after a partial apply, and cancel.
Native REAPER checks verify one-item CC11 editing, unchanged neighboring items
and non-target MIDI, exact Undo/Redo, selected-track isolation, whole-project
backup contents, saving under the same filename, and Undo after saving.
