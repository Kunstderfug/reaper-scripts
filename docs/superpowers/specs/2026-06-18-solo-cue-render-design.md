# Solo-Cue Render (GFX direct) — Design

**Date:** 2026-06-18
**Source script:** `GPhil_tempoSet_render_gfx_direct.lua`
**New script:** `GPhil_soloCue_render_gfx_direct.lua`

## Goal

A new REAPER script that renders **exactly one track** — named `"SOLO"` — for each
region in the project, at that region's auto-detected base tempo. It is derived from
the existing `GPhil_tempoSet_render_gfx_direct.lua`, with the click-render and
full-mix render flows removed entirely. There is no clicktrack, no tempo stepping,
and no full-mix render — only the solo track, one render per region.

## Non-goals

- No click-track rendering.
- No full-mix rendering.
- No tempo-stepping (Min/Max/Step loop) and no tempo-map scaling.
- No shared-library refactor of the source script (out of scope; source untouched).

## Key configuration (constants at top of script)

| Constant | Value | Notes |
|---|---|---|
| `CMD_APPLY_SOLO_CUE` | `"_RSb6214dfe2bae78d7d897e42e57450017be87e017"` | The apply-render-preset action id supplied by the user. |
| `SOLO_TRACK_NAME` | `"SOLO"` | The track to isolate. Looked up by case-insensitive substring match (reuses `get_track_by_name_contains`). |
| `SOLO_CUE_PATTERN_BASE` | `"AUDIO/SOLO_CUE/$region/$project_$region_SOLO_CUE_120"` | Render pattern. The trailing `_120` is the tempo suffix and is replaced by each region's base tempo via the existing `with_tempo_suffix`. |
| `ADD_TO_QUEUE_CMD` | `41823` | File: Add project to render queue, using the most recent render settings (unchanged from source). |
| `EXT_SECTION` | `"renderSoloCue"` | ProjExtState section. **Distinct from the source's `renderTempoSet`** so the two scripts' saved settings never collide. |

## Architecture

Single Lua file. Reuses the source script's tested helpers for tempo capture/restore,
region collection/selection, render-state capture/restore, existing-file filtering,
and serialization — with the click/step/scale machinery deleted.

```
main()
  load_last_params() -> validate saved defaults
  resolve pending grid rows (from a prior GFX Queue click) OR collect regions
    regions = all; if one or more regions are selected, filter to selected only
    (per AGENTS.md: selected regions are a filter ONLY when some are selected)
  prompt_per_region_settings() -> GFX grid (slim)
    on Queue: stash rows + queue options into ProjExtState, defer a fresh main()
  [Queue pass]
    capture: tempo map, render state, region selection, track selection,
             ALL tracks' B_SOLO (solo state snapshot)
    for each group (regions sharing the same base tempo):
      restore tempo map; ensure base-tempo marker at each region's start
      true-solo SOLO: SetMediaTrackInfo_Value(solo, "B_SOLO", 2)
                      set B_SOLO=0 on every other track
      restore render state; apply CMD_APPLY_SOLO_CUE preset
      set SOLO_CUE_PATTERN (with base-tempo suffix)
      filter regions whose output likely already exists (honor skip_existing)
      select those regions; set RENDER_BOUNDSFLAG=5 (regions)
      ADD_TO_QUEUE_CMD
    restore_original_state()  (always — runs after xpcall, fires on error too)
```

## Differences from the source script

| Concern | Source (`tempoSet_render_gfx_direct`) | New (`soloCue_render_gfx_direct`) |
|---|---|---|
| Preset actions | `CMD_APPLY_GPHIL_CLICK` + `CMD_APPLY_GPHIL_RENDER` | One: `CMD_APPLY_SOLO_CUE` |
| Render pattern | `CLICK_PATTERN_BASE` + `RENDER_PATTERN_BASE` | One: `SOLO_CUE_PATTERN_BASE` |
| Isolated track | clicktrack (mute/unmute) | SOLO track via true REAPER solo (`B_SOLO`) |
| Tempo | per-region Min/Max/Step loop + grouping by target tempo + `scale_tempo_map` | One render per region at base tempo; no scaling |
| GFX grid | 8 columns: On/Grp/Region/Base/Min/Max/Step/Click | 4 columns: On/Grp/Region/Base |
| ProjExtState section | `renderTempoSet` | `renderSoloCue` (distinct) |
| Removed | — | clicktrack logic, `scale_tempo_map`, tempo-step loop, Min/Max/Step/Click columns and their buttons |

## Track isolation: true REAPER solo

- **Capture** a solo snapshot of every track up front: `{track, solo = GetMediaTrackInfo_Value(track, "B_SOLO")}`.
- **Apply** before each group's render: `SetMediaTrackInfo_Value(solo_track, "B_SOLO", 2)` (2 = solo-in-place) and `SetMediaTrackInfo_Value(other, "B_SOLO", 0)` for all other tracks.
- **Restore** in `restore_original_state()`: write each track's original `B_SOLO` back, guarded by `reaper.ValidatePtr2(0, track, "MediaTrack*")`.
- The SOLO track is resolved once via `get_track_by_name_contains(proj, SOLO_TRACK_NAME)` (case-insensitive substring). If not found, the script logs a clear error and aborts before any state is captured (so nothing to restore).

`B_SOLO` is used rather than `B_MUTE` so isolation is independent of whatever render
bounds the SOLO_CUE preset uses, and so the script does not fight a user's existing
mute state.

## Region grouping (simplified)

`build_per_region_queue_groups` is reduced to grouping **only by base tempo**:
regions that share a detected base tempo are merged into a single queue entry
(one apply-preset call + one ADD_TO_QUEUE), exactly as the source merges today,
minus the per-target-tempo dimension. Dedup still uses `numeric_group_key`.

Each region still gets its base-tempo marker forced at its start
(`ensure_tempo_marker_at_time(proj, region.pos, base_actual)`) so the SOLO track's
MIDI/tempo-locked items render at the correct base.

## GFX grid (slim)

- **Columns:** `On` (toggle), `Grp` (group id), `Region` (index/#/name), `Base` (double-click to edit).
- **Buttons kept:** Queue, Dry Run, Sort For Queue, Cancel, Save, Load, Copy Last To Selected.
- **Buttons removed:** Fill Down From Selected, Copy To All (these only made sense for the Min/Max/Step columns).
- **Behavior retained:** row enable/disable toggle, double-click-to-edit Base, mouse-wheel scroll, Save/Load via ProjExtState.
- **Save/Load rule (AGENTS.md):** stores per-project region settings and reloads them later. Since Base is the only user-set value here, Save serializes every row's Base (plus identity), and Load matches saved rows to current regions by (number, pos, rgnend, name) and applies the saved Base where matched. Unmatched rows keep their auto-detected Base. The "preserve each row's current detected Base" rule from AGENTS.md applies to the *cross-script* rows that have a detected Base; here, on Load, a matched saved Base intentionally overrides the detected one (that's the point of saving), and unmatched rows' detected Base is preserved.

## State capture/restore guarantee

`restore_original_state()` runs after the `xpcall` body (success **and** error).
It restores, in order:
1. Tempo map (full capture/delete/restore cycle).
2. Render state (numeric + string keys).
3. Region selection (`B_UISEL`).
4. Track selection (40297 deselect-all, then reselect originals).
5. **All tracks' `B_SOLO`** (the new addition).
6. `UpdateArrange()`.

The undo block wraps the whole thing: `Undo_BeginBlock` ... `Undo_EndBlock("soloCue render - queue", -1)`.

## Region selection scope (AGENTS.md compliance)

- If one or more regions are selected when the script runs, the grid shows only
  those selected regions.
- If no regions are selected, the grid shows all regions.

This matches the documented rule for the source script and is preserved verbatim.

## Existing-file handling

Reused unchanged: before queueing each group, the script expands the pattern per
region, probes common audio extensions, and (per the Queue-time dialog choice)
either queues anyway or skips regions whose output likely already exists.
Summary lines are logged to the REAPER console.

## Error handling

- Validate saved defaults up front (clear error box if invalid).
- Resolve the SOLO track before capturing any state; abort cleanly if missing.
- `xpcall` around the queue body; on error, log + message box, then restore.
- Per-group `apply_preset` failure stops early (mirrors source's `stopped_early`).

## Deployment (AGENTS.md)

After editing, copy the new file to
`/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/` and verify the copy
matches (diff). The deployed GPhil folder already contains siblings; this adds one.

## Out of scope / future

- Shared helper module across the tempoSet/stems/soloCue scripts (not now).
- Configurable SOLO_TRACK_NAME via UI (constant-only for now).
