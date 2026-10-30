# REAPER CC curve optimizer

Dependency-free Rust CLI that fits sparse native MIDI CC curves into a **new**
RPP file. The input is never written, and an existing output is never replaced.

```sh
cargo build --release --manifest-path tools/rpp-curve-opt/Cargo.toml
tools/rpp-curve-opt/target/release/rpp-curve-opt input.RPP trial.RPP \
  --track 'VLN 1_1_CH' --cc 11 --tolerance 2
```

`--track` matches one exact track name; omit it to process all tracks.
`--threads N` limits parallel MIDI-source workers inside one project (or native
GCC1 batch). The default is the smaller of eight and the available CPU count;
workers are also limited by the number of sources. Use `--threads 1` for serial
processing. Complete MIDI sources are independent jobs; their results and
statistics are assembled in original source order, so serial and parallel output
are byte-identical. Parsing, pooled-track validation, snapshot handling, and the
final project write remain ordered. A failed worker produces no output file.
When several projects run concurrently, divide the CPU budget across those
projects (for example, four projects × two source workers on eight CPUs).

The REAPER actions use `bin/rpp-curve-opt` beside the installed scripts. When
launched from this source checkout, they also accept the release build at
`tools/rpp-curve-opt/target/release/rpp-curve-opt` produced by the command above.
`--cc` selects controller lanes (default `1,3,11,13,22`). `--cc continuous` selects CC1–31 except data-entry CC6, CC70–95, and CC102–119, excluding bank/LSB, pedals, NRPN/RPN, increment/decrement, and channel-mode messages.
`--tolerance` is in MIDI controller values, default 2 out of 127.
Snapshot removal is on by default; use `--keep-snapshots` to retain them.

### Whole-gesture mode

With jitter/fade repair enabled, repeated short returns to the expression floor
are removed even when they interrupt an already-rising ramp. Dense monotonic
ramps can also interpolate their large samples when ending at a nonzero level.
Isolated resets, sustained low states and existing nonlinear curves remain
protected. Repairs intentionally depart from the raw collision samples and
are reported separately from the curve-fitting tolerance.

Explicit linear CC segments (`ENV 1`, native shape flag 16) are fitted just like
recorded point runs. Existing nonlinear curves remain protected. Replaced or
removed linear anchors have their old ENV metadata removed, and linear-to-Bezier
fits receive native tension metadata.

On a captured 620-source project batch at tolerance 4 with gesture/jitter repair,
this correction reduced the selected CC anchors from 417,064 to 107,173 (74.3%).
CC11 went from 119,006 to 29,799 (75.0%). Batch processing took 1.51 seconds on
the local MacBook; raw batch bytes fell 55.8%. These are copied MIDI measurements,
not a saved-project size estimate or an audio listening comparison.

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
## GFX window

The compact window uses a 660 × 530 canvas and places shaping controls directly
below the detected lane rows. All scopes, controller toggles and reports remain
available.

The pin icon at the upper right toggles always-on-top. It starts enabled and
remembers your choice between runs. This uses js_ReaScriptAPI; if unavailable,
the icon is disabled and the remaining optimizer controls still work.

Load `GPhil_optimizeProjectCC_gfx.lua` in REAPER's Actions window using
**New action → Load ReaScript**, then run it. The original prompt action remains
available.

The window defaults to **Auto selection**: it follows selected MIDI items or
selected tracks, using the most recently changed selection when both exist.
Selection changes update the scope and detected lanes while the window stays
open, including track selection changes that do not dirty the project.
Manual scope buttons keep the chosen scope. Whole project is always explicit.
The window offers selected MIDI items, selected tracks, or the whole project;
detected continuous CC lanes appear as individual toggles. **Select detected**
selects the eligible lanes and follows newly detected lanes. Clicking individual
lanes or **Clear** switches to a custom CC choice, preserved across selection
changes. Only lanes present in the current scope are sent to the optimizer.
The lane list is the union across sources: an item missing a chosen CC is skipped
for that lane. **Other used CCs** allows explicit overrides for
normally excluded switch/data lanes. Selection changes refresh the detected
lanes; use **Refresh selection** to rescan manually. Tolerance ranges from 0.5
to 16 MIDI values. Jitter/fade repair can be toggled independently.

**Optimize CCs** applies directly through the same atomic Undo transaction.
Whole-project scope creates a backup and saves under the current filename.
The result shows elapsed time; **Last report** includes the optimizer details
and backup path, or the complete failure and restore status. On a read-back
mismatch the event check remains enforced, attempted sources are restored, and
original/expected/actual buffers plus an event-level report are written locally
under REAPER's `Data/GPhil/CC-diagnostics` directory. No diagnostics are uploaded.
SWS cleanup remains a separate action. Escape closes the window.

Apply and restore verification accept one observed REAPER 7.83 normalization:
an attached Bezier `CCBZ` type byte of 2 becomes 0. Scratch-item round trips of
the captured original and optimized buffers produced identical stored item
chunks and every native CC shape/tension for the two forms. All event offsets,
flags, values and tension bytes must still match exactly; other type changes
are rejected. This avoids false apply and restore failures on existing curves.

Install the GFX entry point alongside the original action, plus
`lib/cc_window.lua`, `lib/cc_widgets.lua`, `lib/cc_selection.lua`, and
`lib/cc_verify.lua`, and `lib/cc_pin.lua`, retaining the existing optimizer
modules and `bin/rpp-curve-opt` binary.

### Automatically optimize after MIDI recording

`GPhil_autoOptimizeRecordedCC_install.lua` registers the two actions, enables
monitoring immediately, and adds an idempotent stanza to REAPER's
`Scripts/__startup.lua`. Existing startup code (including Reaticulate) is retained;
a timestamped `.gphil-backup-*` copy is written before changing it. Deploy the
scripts, `lib/cc_*.lua` modules and optimizer binary to `Scripts/GPhil` first.

Use **Script: GPhil_autoOptimizeRecordedCC_toggle.lua** in the Actions list or
assign it to a toolbar/shortcut. Its toolbar state shows enabled/disabled. Off
persists across REAPER launches. The separate `..._start.lua` action owns the
background monitor, avoiding REAPER's already-running-script prompt on toggles.
There is no window, console pop-up or manual action after each recording.

The monitor processes CC **1, 3, 11, 13, 21, 22** at **tolerance 4**, with jitter
and collided-fade repair. It waits for recording to stop and MIDI to stabilize
(about 0.8 seconds), then applies changes in place with **one Undo step for the
entire recording pass**. Ordinary playback stops do nothing. Recording that
continues into playback waits until transport is fully stopped. Enabling the
monitor midway through a recording skips that pass. Project switches cancel the
pending pass. Projects are never auto-saved and SWS snapshots are never removed.

Idle snapshots are refreshed at the first recording frame. Previously existing
CC events are matched by source tick, channel, controller and value, regardless
of selection. Only newly added runs of at least three target CC events are
fitted; old CC anchors split runs and remain untouched, including their curve
metadata. First-frame incoming CCs are conservatively protected too. Notes and
all other MIDI events retain their timing, values, flags and order. Each run
retains its boundary anchors and its final outgoing segment. New overdub takes
also protect matching MIDI copied from earlier takes in the same item. Dense
old CC points interleaved with a new overdub can therefore limit reduction.

If an existing take's source mapping changes, that take is skipped. File-backed
MIDI, ambiguous multiple-take pooling without SWS, or pools shared outside the
recorded scope refuse the pass without edits. The shared verified transaction
restores originals on apply failure; Undo is also available. This preserves
surviving earlier MIDI; it does not reverse deletions caused by REAPER's own
MIDI **replace** recording mode. The feature is intended for normal recording
and MIDI overdub.

Results/errors are appended to
`REAPER/Data/GPhil/CC-after-recording.log`. `lib/cc_recording_watch.lua` owns
transport transitions, `cc_recording_snapshot.lua` captures take identity and
source mapping, `cc_recording_diff.lua` isolates and merges new CC runs, and
`cc_recording_service.lua` owns lifecycle and fitting. Manual and automatic
editing share `cc_transaction.lua` for readback verification and one-step Undo.

Regression checks: `lua tests/cc_recording.lua`, `lua tests/cc_optimizer.lua`,
`lua tests/cc_verify.lua`, `lua tests/cc_selection.lua`, and
`lua tests/cc_recording_service.lua`. In REAPER,
`tests/native_cc_recording.lua` proves a two-take transaction and exact Undo;
`tests/native_cc_recording_transport.lua` creates a disposable project, records
six CC lanes through the Virtual MIDI Keyboard in overdub mode, stops the real
transport, checks the background result and Undo, then restores the previous
project tab. The transport test turns the monitor off when finished; run the
installer or toggle to enable it afterward.
