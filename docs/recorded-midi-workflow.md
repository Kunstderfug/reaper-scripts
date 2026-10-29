# Automatic MIDI recording preparation

Two mutually exclusive toolbar modes are available:

- **Align MIDI** (`GPhil_alignRecordedMidi_toggle.lua`): expand item bounds,
  then open all recorded MIDI items. CC events and curves remain unchanged.
- **Align + CC** (`GPhil_prepareRecordedMidi_toggle.lua`): expand bounds,
  optimize continuous CC curves, then open all recorded MIDI items.

Load these scripts from REAPER's Actions list (Main section, New action → Load
ReaScript), then add toolbar buttons or shortcuts. Run a mode before recording
to enable; run it again to disable. Enabling the other mode switches the first
off. Both buttons reflect the active mode. If REAPER asks what to do with the
running script, choose **Terminate instance** to switch it off. Change modes
between recordings; switching during recording skips that recording.

Start with Align MIDI while evaluating curve optimization. Alignment mode does
not call the optimizer and works without its binary. To try the curve engine
on an existing recording later, select the items and run
`GPhil_optimizeProjectCC_gfx.lua`; Undo allows comparison with the original.

## One editor for all recorded parts

The script selects every recorded MIDI item before invoking REAPER's built-in
editor action. Window sharing and which parts are editable follow REAPER's
MIDI editor preferences. To edit two or four recorded tracks together, set
**Preferences → Editing Behavior → MIDI Editor** to **One MIDI editor per:
project** and **Open all selected MIDI items**. Link item selection to
editability and disable the restriction that only the active track is editable.
In the editor's track list, confirm all recorded parts have editing enabled.

Select the required notes across those editable parts (for identical overlaid
parts, marquee-select the passage), then invoke Quantize once. REAPER supports
quantizing selected notes across multiple editable items. Clicking a single
note does not automatically select its counterpart on another track: the notes
to quantize must be selected in each part. There is no need to cycle the active
part with N when the required notes are selected across all editable parts.

These editor preferences require a one-time setup; the script does not change
global MIDI editor settings. See the [REAPER User Guide, MIDI editing with
multiple items](https://dlx.reaper.fm/userguide/html/).

While enabled, stopping a recording waits 0.2 seconds for REAPER to finish, then:

1. Expands the recorded MIDI item's start/end to enclosing barlines, respecting
   the project's tempo and time signatures. Region starts and ends limit the
   expansion even when they are between barlines. An edge already at a region
   boundary stays there. Adds no extra lead-in bar. MIDI note timing stays unchanged.
2. In **Align + CC** mode only, optimizes detected continuous CC lanes using tolerance 4 and jitter/fade
   repair, with the same engine as `GPhil_optimizeProjectCC.lua`. Switch/data
   lanes (including sustain) are excluded by automatic detection.
3. Selects the recorded MIDI items and opens the built-in MIDI editor. Quantize
   notes manually, close the editor, then record the next part as usual.

The two processing steps share one Undo action. A processing failure restores
the recorded items and reports the error in the REAPER console. Nothing is
automatically saved. The last result is in transient ExtState
`GPhil_PrepareRecordedMidi/last_report`.

The watcher detects new items, new active takes, and changed MIDI from overdubs
on tracks armed when recording begins. Other selected items are untouched.
Audio recordings and canceled/deleted recordings are ignored. Pause alone does
not trigger processing. Enable before recording; enabling midway skips that
recording. Switching project tabs abandons the pending session. The toggle
does not automatically restart after quitting REAPER.

Locked items, shared MIDI pools, repeating/file-backed sources and other unsafe
edge expansions retain the existing alignment exclusions and are skipped for
both alignment and optimization. Skipped items still open for manual editing.
Standalone markers do not override barlines. For nested/overlapping regions,
the nearest containing boundary for each edge wins. Nearby overhangs are
trimmed to the region boundary when most of the item lies in that region and
the overhangs fit within its boundary bars. This also repairs edges previously
rounded outward to bars. Items spanning adjacent regions or extending beyond
those boundary bars are not collapsed into a single region. Region trims may
hide or cut off playback of notes beyond the boundary; MIDI events retain
their source timing and data, and Undo restores the original item edges.

Install the entry scripts and `lib/` dependencies together. Align + CC also
requires `bin/rpp-curve-opt`.
Tests: `lua tests/midi_record_watch.lua`, `lua tests/midi_record_finish.lua`,
`lua tests/midi_record_toggle.lua`, `lua tests/midi_item_bounds.lua`, and
`lua tests/cc_optimizer.lua`.
