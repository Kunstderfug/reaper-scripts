---
name: derive-reaper-render-script
description: Derive a new GPhil_* REAPER queue or direct-render script from an existing script when changing the target track, preset, output pattern, or render mode. Preserve tempo/meter metadata and project state.
---

# Derive a REAPER Render Script

This skill creates new `GPhil_*.lua` queue or direct-render scripts by **deriving** them from existing ones in `/Volumes/DEV/reaper-scripts/`. Retain the source's region collection, GFX grid, and grouping structure, then audit tempo handling and isolation against the chosen mode.

## When to use

Trigger when the user wants a *new* render script that is a variation on an existing one. Signals:
- "make/create/build another script based on [X]"
- "like [X] but for [track/preset/pattern]"
- names a source script + a list of changes (swap track, swap preset id, change pattern)

If the user instead wants to *fix* or *modify* an existing script in place, don't use this skill — just edit it directly.

## The core method: copy, then edit

**Always start by copying the source script byte-for-byte, then edit in place.** Never rewrite from a blank file. This preserves the source structure; audit the inherited tempo handling before relying on it. A copied helper can carry a bug into the new script.

```bash
cp /Volumes/DEV/reaper-scripts/<SOURCE>.lua \
   /Volumes/DEV/reaper-scripts/<NEW>.lua
diff -q <SOURCE>.lua <NEW>.lua && echo IDENTICAL   # must print IDENTICAL
```

### Naming the new file

Derive the filename by swapping the target token in the source name. The convention is `GPhil_<target>Cue_render_gfx_direct.lua`, lowercasing the target. Examples:

| Source | Target track | New filename |
|---|---|---|
| `GPhil_soloCue_render_gfx_direct.lua` | BASS | `GPhil_bassCue_render_gfx_direct.lua` |
| `GPhil_soloCue_render_gfx_direct.lua` | LEAD VOCAL | `GPhil_leadVocalCue_render_gfx_direct.lua` (camelCase the token, strip spaces) |

If the user already named the file, use their name. Give direct-render and queue variants distinct filenames and ExtState sections; include the mode when the target token would otherwise collide.

## Choose the render mode before copying

Use the user's named source when supplied. Otherwise choose the closest behavior:

| Requested behavior | Source |
|---|---|
| Quick region render at the original project tempo map | `GPhil_defaultTempo_render_gfx_direct.lua` |
| Quick click-only region render at the original map | `GPhil_click_render_gfx_direct.lua` |
| Single-target queue at each region's detected base tempo | `GPhil_soloCue_render_gfx_direct.lua` |
| Tempo-stepping queue or click + full-mix flows | `GPhil_tempoSet_render_gfx_direct.lua` |

Inspect the action used by the source: filename suffix `_direct` does not identify the execution mode. The quick scripts use synchronous action `42230`; queue creation uses `41823`.

**Tempo-map contract:** original-map renders leave the map untouched, including cleanup. Do not inherit deletion/reinsertion or region-start tempo insertion into that mode. Any mode that temporarily changes the map must preserve the complete original map through success, cancellation, termination, and failure. Before inheriting, adding, or changing any marker capture, restore, scaling, or region-start adjustment, read [tempo-map preservation](references/tempo-map-preservation.md) and apply its regression checks. Marker counts and BPM values alone do not establish preservation.

## The four things that change per derivation

Every derivation is some combination of these four edits. Get these right and the script usually works; get them wrong and you get a script that runs but renders the wrong thing.

### 1. Preset action id (cfillion "Apply render preset" generated action)

Near the top of the file:

```lua
local CMD_APPLY_SOLO_CUE = "_RSb6214dfe2bae78d7d897e42e57450017be87e017"
```

The user supplies this id. It points at a render preset configured in REAPER via cfillion's "Apply render preset (create action)" script. **The preset's own configuration matters as much as the id** — see the Isolation section.

### 2. Render pattern

```lua
local SOLO_CUE_PATTERN_BASE = "AUDIO/SOLO_CUE/$region/$project_$region_SOLO_CUE_120"
```

The trailing number (`_120`) is a tempo suffix; the existing `with_tempo_suffix` helper replaces it with each region's base tempo at render time. `$region`, `$regionnumber`, and `$project` are expanded by `expand_render_pattern_for_region`. When renaming, also rename the local variable and update every reference.

### 3. Target track name

```lua
local SOLO_TRACK_NAME = "SOLO"
```

Matched case-insensitively by substring. `find_solo_track` prefers a *selected* track whose name contains the fragment, falling back to the first match — so users with multiple candidate tracks can disambiguate by selecting one.

### 4. ProjExtState section

```lua
local EXT_SECTION = "renderSoloCue"
```

**Must be unique per script.** If two scripts share an `EXT_SECTION`, their saved grid settings collide. Always rename when deriving.

### Renaming the target identifier family

The four edits above change *values*. A track-swap derivation (e.g. SOLO → BASS) also has a family of target-flavored **identifiers** worth renaming for clarity. Rename these and update every reference; don't leave a BASS script full of `solo_*` names.

| Source identifier | Rename to |
|---|---|
| `find_solo_track` | `find_<target>_track` (e.g. `find_bass_track`) |
| `solo_track` (local) | `<target>_track` |
| `selected_solo_count` | `selected_<target>_count` |
| `original_solo_mute` | `original_<target>_mute` |
| `SOLO_TRACK_NAME` | `<TARGET>_TRACK_NAME` |
| `CMD_APPLY_SOLO_CUE` | `CMD_APPLY_<TARGET>_CUE` |
| `SOLO_CUE_PATTERN_BASE` | `<TARGET>_CUE_PATTERN_BASE` |

Also update user-visible strings so logs and dialogs describe the right track:
- The Undo block label: `Undo_EndBlock("soloCue render - queue", -1)` → `"bassCue render - queue"`
- The console banner and log lines (e.g. `"=== soloCue render - queue ==="`, `"SOLO track: %s"`)
- Error dialogs ("SOLO track not found...")

The fastest reliable way is a whole-file rename pass after the value edits, not hunting references by hand.

## Isolation: the part that silently breaks

Match isolation to the preset's render source. Solo state by itself does not establish selected-track isolation; use the selected-track preset contract below and verify the resulting audio.

For a selected-track preset, use **track selection + mute management**:

```lua
local function select_only_track(track)
    reaper.Main_OnCommand(40297, 0)   -- Track: Unselect all tracks
    if track then
        reaper.SetTrackSelected(track, true)
    end
end

-- Capture the target's mute state once, before any rendering
local original_target_mute = reaper.GetMediaTrackInfo_Value(target_track, "B_MUTE")

-- Per render group:
select_only_track(target_track)
if original_target_mute ~= nil then
    reaper.SetMediaTrackInfo_Value(target_track, "B_MUTE", 0)  -- force unmute
end
-- ... apply preset, select regions, queue ...

-- After each group, restore mute and selection so the next group starts clean
if original_target_mute ~= nil then
    reaper.SetMediaTrackInfo_Value(target_track, "B_MUTE", original_target_mute)
end
reaper.Main_OnCommand(40297, 0)
for i = 1, #prev_sel do
    reaper.SetTrackSelected(prev_sel[i], true)
end
```

Why this works: the render preset is configured (in REAPER) to render **selected tracks**, and the script sets region bounds (`RENDER_BOUNDSFLAG=5`). So "select only the target track" = "render only the target track". The force-unmute is defensive — if the target was muted when the script ran, the render would otherwise come out silent.

**The preset configuration is part of the contract.** Establish that the named preset renders selected tracks before implementing track isolation. Use existing session confirmation or inspect the preset configuration; ask only if that contract remains unknown. A preset rendering the master mix or source media needs a different isolation approach. `RENDER_BOUNDSFLAG=5` selects region bounds; it does not select the render source.

### State to capture and restore

Capture before the first mutation, wrap rendering/queueing in `xpcall`, and restore after it on both success and error:

- Complete tempo map **only for modes that modify it**, following the linked preservation reference.
- Render settings (`capture_render_state` / `restore_render_state`).
- Region selection (`capture_region_selection` / `restore_region_selection`).
- Track selection (`prev_sel`, restored via `40297` + reselect).
- Every track mute state changed by the script (including an additionally muted SOLO track).

For sequential direct rendering, register idempotent `reaper.atexit` cleanup before mutation and call the same cleanup after the protected body. Advance only after the current render is confirmed complete; cancellation stops the entire sequence. See the preservation reference for the completion contract.

Keep cleanup outside the protected render body. A failing cleanup step must still allow the remaining state restorations and `Undo_EndBlock` to run, and report any restoration failure. Original-map mode must make no tempo-map writes even on the error path.

## Process lessons (these matter as much as the code)

### `luac -p` is necessary but not sufficient

`luac -p <file>` catches syntax errors. Run it after every edit. **But it cannot catch undefined-function calls** — in Lua, calling an undefined local just resolves to a nil global at runtime, producing a "attempt to call a nil value" error only when that line executes. This bit us during the soloCue derivation when a splice accidentally deleted a block of helper functions; `luac -p` passed and the bug only surfaced as a runtime crash.

**Mandatory complement: structural grep after any deletion.** When you delete or replace a multi-line block, grep for every symbol the new code depends on and confirm it still has a definition:

```bash
for fn in capture_render_state restore_render_state filter_regions_for_existing_outputs; do
  echo "$fn: $(grep -c "local function $fn" <NEW>.lua) (need >= 1)"
done
```

If any count is 0, you deleted a helper that's still called. Restore it.

### Beware line-number-based splices

When replacing a function by line range (e.g. `sed -n '921,1739p'` or a Python range-replace), **recompute the range from the current file state immediately before the splice**. Earlier edits in the same session shift line numbers. During soloCue, a range computed from the source file's layout was applied to a file whose lines had shifted, silently eating an adjacent block of helpers.

Safer: use the Edit tool with the full old function body as the match string (it fails loudly if the match drifts), or locate boundaries by content (`grep -n "^local function foo"`) right before splicing.

### AGENTS.md deploy step is mandatory

After every edit to a `GPhil_*.lua` script, per `AGENTS.md`:

```bash
cp /Volumes/DEV/reaper-scripts/<NEW>.lua \
   "/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/<NEW>.lua"
diff -q <repo>/<NEW>.lua "<deploy>/<NEW>.lua" && echo IDENTICAL
```

Deploy runtime helper files too, retaining their relative paths, and byte-compare every copied file. The deployed copy is what REAPER actually runs. An edited repo file that isn't deployed has no effect.

### Verify behavior as well as syntax

Use Lua API mocks to exercise the actual derived helpers and main render path. For scripts that modify tempo, run the regression cases in the preservation reference; for original-map mode, make every tempo writer fail in the mock so an unintended edit is caught. Include success and an injected render/queue failure, then compare restored state. Existing entry points are `lua tests/tempo_marker_flags.lua` and `lua tests/click_direct_render.lua`; extend coverage for the new script rather than reporting only the source's tests.

Mocks establish script logic, not REAPER's actual queue snapshots or rendered audio. A live check must compare tempo/meter marker values and checkboxes before/after queue creation, inspect queued project snapshots, and listen to the isolated output. Report which automated checks passed and whether the live check was performed; do not claim host behavior was verified from syntax checks or mocks.

## Reference: how the queue loop fits together

```
main()
  load_last_params -> validate
  find target track (prefer selected, guard against multi-select)
  if pending grid rows (from prior Queue click): use them
  else: collect regions (selected-only filter when some selected, else all)
        prompt_per_region_settings -> GFX grid
          on Queue: stash rows to ProjExtState, defer fresh main()
  [Queue pass]
    Undo_BeginBlock
    capture: complete tempo map if modified, render state, region selection, prev_sel, changed mute states
    for each group (regions sharing base tempo):
      if changing tempo: restore complete map; apply intentional tempo changes
      otherwise: leave tempo map untouched
      select_only_track(target); force-unmute target
      restore render state; apply preset
      set pattern (with tempo suffix); filter existing outputs
      select regions; RENDER_BOUNDSFLAG=5; queue (41823) or render (42230)
      restore target mute; restore prev_sel
    restore_original_state()   (after xpcall; attempt every restoration)
    Undo_EndBlock
```

The GFX grid (`prompt_per_region_settings`) is a `gfx.*` defer loop. When slimming it, keep these columns/buttons; drop the rest:
- **Keep:** On, Grp, Region, Base columns; Queue or Render (matching the chosen mode), Dry Run, Sort, Cancel, Save, Load, Copy Last To Selected buttons. Preserve automatically detected Base during cross-row copying and Save/Load.
- **Drop:** Min/Max/Step/Click columns and Fill Down / Copy To All buttons — these only exist in the tempo-stepping source.

## Quick checklist for a derivation

- [ ] Copy source → new file, verify `IDENTICAL`, `luac -p` passes
- [ ] Establish selected-track preset contract from session confirmation, preset inspection, or user clarification
- [ ] Swap preset id, pattern, target track name, `EXT_SECTION` (unique!)
- [ ] Rename the target identifier family (`find_<target>_track`, `<target>_track`, `original_<target>_mute`, etc.) + user-visible strings (Undo label, logs)
- [ ] Isolation uses `select_only_track` + force-unmute, NOT `B_SOLO`
- [ ] Original-map mode makes no tempo writes; modifying mode meets the linked preservation contract
- [ ] Changed state is captured before mutation; every cleanup is attempted after success/error
- [ ] Actual derived script passes tempo/meter and render/queue failure regressions
- [ ] After any deletion: structural grep confirms every called function is still defined
- [ ] `luac -p` passes
- [ ] Deployed copy is byte-identical (`diff -q` → `IDENTICAL`)
- [ ] Report automated results and live REAPER verification status separately
