# MIDI Solo Cue Export — Design

**Date:** 2026-06-18
**Status:** Draft, awaiting user review
**Script:** `GPhil_exportMidiSoloCue.lua`

## Purpose

Export each selected MIDI media item to a single-track Standard MIDI File
(`.mid`) under a region/tempo-aware path, with the project's tempo (and time
signature) map embedded in the file so the exported MIDI plays back at the
correct tempo in any host.

Derived from MPL's "Export selected items as MIDI files" script, but with:

- A new output path scheme: `AUDIO/SOLO_CUE/<region>/<project>_<region>_SOLO_CUE_<tempo>.mid`
- Tempo rounding that kills float noise (`59.999999` → `60`)
- **Embedded tempo and time-signature meta events** (the MPL original wrote
  only note/CC events and silently dropped the project tempo)
- The CC/pitch-bend/aftertouch envelope-smoothing pass removed (export only)

## Iteration & resolution rules

| Token | Source |
|-------|--------|
| `$region` | The region whose `[pos, rgnend]` spans the item's `D_POSITION`. If several regions overlap the item, the one with the smallest `pos` wins. |
| `$project` | `reaper.GetProjectName`, path stripped, `.rpp` / `.rpp-bak` / other extension stripped, default `"untitled"`. |
| `$tempo` | `reaper.TimeMap2_GetDividedBpmAtTime(proj, region.pos)` — the region's start BPM — rounded to the nearest integer via `math.floor(tempo + 0.5)`. |

### Edge cases

- **Selected item not inside any region** → skip silently, one console line:
  `SKIP: item has no containing region: <take name>`.
- **Selected item with no active take** → skip silently, one console line.
- **Selected item whose active take is not MIDI** → warn + continue:
  `WARN: skipping non-MIDI item: <take name>`.
- **Target file already exists** → overwrite.

## Output path

```
<GetProjectPath()>/AUDIO/SOLO_CUE/<region>/<project>_<region>_SOLO_CUE_<tempo>.mid
```

`$region` and `$project` are sanitized: characters illegal on macOS/Windows
(`/ \ : * ? " < > |`), control chars, and tabs/newlines are replaced with `_`;
runs of `_` are collapsed; leading/trailing `_` trimmed. `$tempo` is already a
clean integer string. Directories are created with `RecursiveCreateDirectory`.

## MIDI file format

Standard MIDI File, format 0 (single track), one `MTrk` chunk:

1. **Header (`MThd`):** format `0`, track count `1`, division = PPQ derived
   from the take via `MIDI_GetPPQPosFromProjQN` / project-QN math (reuse MPL's
   `GetTakePPQ` helper).
2. **Event stream** — the take's raw events from `MIDI_GetAllEvts`, **merged
   with injected tempo + time-signature meta events** (see below), sorted by
   absolute PPQ, then re-delta-encoded with MIDI variable-length quantities.
3. **End-of-track** meta event: `FF 2F 00`.

MPL's `makeoffset` helper (variable-length delta encoding) is reused unchanged.

## Tempo & time-signature embedding

For each exported item, after collecting the take's raw events:

1. **Enumerate project tempo markers** with `CountTempoTimeSigMarkers` +
   `GetTempoTimeSigMarker`. Keep every marker whose `timepos` (in seconds)
   falls within `[region.pos, region.rgnend]`.
2. **Convert time → PPQ** for each marker via
   `MIDI_GetPPQPosFromTime(take, timepos)`.
3. **Emit a Set Tempo meta event** per marker:
   `FF 51 03 <mpqn bytes>`, where `mpqn = round(60000000 / bpm)` packed as
   3 bytes big-endian.
4. **Emit a Time Signature meta event** per marker:
   `FF 58 04 <nn> <dd> <cc> <bb>`, where `dd = log2(denom)` and `cc`/`bb` are
   REAPER's clock/32nd values (use defaults `24`/`8` when the marker reports
   `0`, which is REAPER's "default" sentinel).
5. **Merge** these meta events into the take's event list, then sort the
   combined list by ascending absolute PPQ. Meta events at the same PPQ as a
   note event sort **before** the note event (standard SMF ordering: tempo
   first, then notes).
6. **Clamp to track start:** markers whose PPQ precedes the take's own PPQ
   origin are written at delta `0` at the head of the track (they are still
   earlier in absolute time; nothing is dropped).

The filename `$tempo` is unaffected — it stays the rounded region-start BPM.

## Dependencies & APIs used

All stock REAPER Lua API; no external scripts, no SWS requirements beyond
what the other GPhil scripts already assume.

- `CountSelectedMediaItems`, `GetSelectedMediaItem`, `GetActiveTake`,
  `TakeIsMIDI`, `ValidatePtr2`
- `GetMediaItemInfo_Value` (`D_POSITION`)
- `EnumProjectMarkers3` (region enumeration)
- `CountTempoTimeSigMarkers`, `GetTempoTimeSigMarker`
- `TimeMap2_GetDividedBpmAtTime`, `MIDI_GetPPQPosFromTime`,
  `MIDI_GetPPQPosFromProjQN`, `TimeMap2_timeToQN`
- `MIDI_GetAllEvts`, `MIDI_Sort`
- `GetProjectPath`, `GetProjectName`, `RecursiveCreateDirectory`
- `ShowConsoleMsg`

## Conventions

- `---@diagnostic disable-next-line: undefined-global` + `local reaper = reaper`
  (matches `GPhil_createRegionsFromSelectedItemsTakeNames.lua`).
- A small `log()` helper writing to the REAPER console.
- **No undo block** — exporting files is not an undoable project edit.
- **No `defer` / GFX UI** — synchronous, run-once.
- **Deploy step:** after writing the script, copy it to
  `/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/GPhil_exportMidiSoloCue.lua`
  and verify the copy matches (per `AGENTS.md`).

## Console output

On every run the script prints a summary block:

```
=== GPhil MIDI Solo Cue Export ===
Project: <name>
Output root: <GetProjectPath()>/AUDIO/SOLO_CUE
Items selected: N
--------------------------------------
EXPORT: <full path>  (region=<r>, tempo=<t>)
SKIP:   item has no containing region: <take>
WARN:   skipping non-MIDI item: <take>
--------------------------------------
Exported: A   Skipped: B   Warned: C
```

## Out of scope

- CC / pitch-bend / aftertouch envelope smoothing (the MPL smoothing pass).
- GFX region grid (already covered by other scripts).
- Render-queue interaction — this writes `.mid` files directly, it does not
  touch `RENDER_PATTERN` or the render queue.
- Per-region tempo variant sweeps (handled by the tempo-set scripts).
