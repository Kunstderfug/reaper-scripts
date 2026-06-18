---
name: derive-reaper-render-script
description: How to create a new GPhil_* REAPER render-queue script by deriving it from an existing one in this repo. Use whenever the user asks to make, create, or build a new render script "like" or "based on" an existing GPhil_*.lua script — e.g. "make a script like soloCue but for violin", "another script based on tempoSet that renders only drums", or any request that swaps the target track, preset, or render pattern while reusing the proven queue/grid/isolation machinery.
---

# Derive a REAPER Render Script

This skill creates new `GPhil_*.lua` render-queue scripts by **deriving** them from existing ones in `/Volumes/DRIVE/DEV/reaper-scripts/`. It does NOT write render scripts from scratch — the proven helpers (tempo-map capture/restore, region collection, GFX grid, queue grouping) are too valuable to reinvent, and the isolation mechanism is subtle enough that getting it wrong produces silently-broken renders.

## When to use

Trigger when the user wants a *new* render script that is a variation on an existing one. Signals:
- "make/create/build another script based on [X]"
- "like [X] but for [track/preset/pattern]"
- names a source script + a list of changes (swap track, swap preset id, change pattern)

If the user instead wants to *fix* or *modify* an existing script in place, don't use this skill — just edit it directly.

## The core method: copy, then edit

**Always start by copying the source script byte-for-byte, then edit in place.** Never rewrite from a blank file. This preserves 2000+ lines of tested helpers that you will not get right from memory.

```bash
cp /Volumes/DRIVE/DEV/reaper-scripts/<SOURCE>.lua \
   /Volumes/DRIVE/DEV/reaper-scripts/<NEW>.lua
diff -q <SOURCE>.lua <NEW>.lua && echo IDENTICAL   # must print IDENTICAL
```

### Naming the new file

Derive the filename by swapping the target token in the source name. The convention is `GPhil_<target>Cue_render_gfx_direct.lua`, lowercasing the target. Examples:

| Source | Target track | New filename |
|---|---|---|
| `GPhil_soloCue_render_gfx_direct.lua` | BASS | `GPhil_bassCue_render_gfx_direct.lua` |
| `GPhil_soloCue_render_gfx_direct.lua` | LEAD VOCAL | `GPhil_leadVocalCue_render_gfx_direct.lua` (camelCase the token, strip spaces) |

If the user already named the file, use their name. If neither, ask.

## Default source: `GPhil_soloCue_render_gfx_direct.lua`

This is the simplest script in the family and the best starting point. It does one render per region at the region's auto-detected base tempo, isolating a single named track. If the user wants tempo-stepping or multiple render flows (click + full-mix), derive from `GPhil_tempoSet_render_gfx_direct.lua` instead — but expect a much larger diff.

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

This is the single most important lesson in this skill. Read it carefully.

**`B_SOLO` does not constrain what a render produces.** Solo is a *monitoring* state — it affects playback, not rendering. A script that sets `B_SOLO=2` on a track and then renders will render every track, not just the soloed one. The render will look fine; the output will be wrong; `luac -p` will pass; there is no error. This exact bug happened during the soloCue derivation and required a user test to catch.

The proven isolation pattern (used by every working script in this repo) is **track selection + mute management**:

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

Why this works: the render preset is configured (in REAPER) to render **selected tracks** within region bounds (`RENDER_BOUNDSFLAG=5`). So "select only the target track" = "render only the target track". The force-unmute is defensive — if the target was muted when the script ran, the render would otherwise come out silent.

**The preset configuration is part of the contract.** Before writing a derivation that isolates a track, confirm with the user that the named preset is bound to render selected tracks. If the preset is bound to master mix or source media instead, track selection won't isolate and you need a different approach (out of scope — ask the user).

**This confirmation blocks the work — do not proceed without it.** Do not write isolation code (even inherited-from-source isolation) on the assumption that "it worked for SOLO so it'll work here." The source's isolation is correct *because* the SOLO_CUE preset happens to be bound to selected tracks; a different preset with different bounds makes the identical code wrong. If the user can't confirm the preset's bounds yet, stop and ask — do not ship a derivation that might silently render the wrong thing. (This is exactly the bug that required a user test to catch during soloCue: the code looked right, `luac -p` passed, and the output was wrong.)

### State to capture and restore (always)

Wrap the whole queue in `Undo_BeginBlock`/`Undo_EndBlock` and an `xpcall`. Capture up front, restore in a function called both on success and error:

- Tempo map (`capture_tempo_map` / `restore_tempo_map`)
- Render settings (`capture_render_state` / `restore_render_state`)
- Region selection (`capture_region_selection` / `restore_region_selection`)
- Track selection (`prev_sel` list, restored via `40297` + reselect)
- Target track's `B_MUTE` (shown above)

Restore must run **after** the `xpcall`, not inside it, so it fires on error too.

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
cp /Volumes/DRIVE/DEV/reaper-scripts/<NEW>.lua \
   "/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/<NEW>.lua"
diff -q <repo>/<NEW>.lua "<deploy>/<NEW>.lua" && echo IDENTICAL
```

The deployed copy is what REAPER actually runs. An edited repo file that isn't deployed has no effect.

### The user is the only verifier

REAPER scripts cannot be exercised headless. `luac -p` + structural grep catch construction errors, but **render correctness can only be confirmed by the user running the script in REAPER** and listening to the output. Never claim a render-script change is verified based on static checks alone. Say "compiles, deployed, ready for you to test in REAPER" — not "verified".

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
    capture: tempo map, render state, region selection, prev_sel, target B_MUTE
    for each group (regions sharing base tempo):
      restore tempo map; ensure base-tempo marker at each region start
      select_only_track(target); force-unmute target
      restore render state; apply preset
      set pattern (with tempo suffix); filter existing outputs
      select regions; RENDER_BOUNDSFLAG=5; ADD_TO_QUEUE_CMD
      restore target mute; restore prev_sel
    restore_original_state()   (always, after xpcall)
    Undo_EndBlock
```

The GFX grid (`prompt_per_region_settings`) is a `gfx.*` defer loop. When slimming it, keep these columns/buttons; drop the rest:
- **Keep:** On, Grp, Region, Base columns; Queue, Dry Run, Sort For Queue, Cancel, Save, Load, Copy Last To Selected buttons.
- **Drop:** Min/Max/Step/Click columns and Fill Down / Copy To All buttons — these only exist in the tempo-stepping source.

## Quick checklist for a derivation

- [ ] Copy source → new file, verify `IDENTICAL`, `luac -p` passes
- [ ] **Confirm with user: preset is bound to render selected tracks** (blocks — do not proceed without it)
- [ ] Swap preset id, pattern, target track name, `EXT_SECTION` (unique!)
- [ ] Rename the target identifier family (`find_<target>_track`, `<target>_track`, `original_<target>_mute`, etc.) + user-visible strings (Undo label, logs)
- [ ] Isolation uses `select_only_track` + force-unmute, NOT `B_SOLO`
- [ ] All five state captures present and restored after xpcall
- [ ] After any deletion: structural grep confirms every called function is still defined
- [ ] `luac -p` passes
- [ ] Deployed copy is byte-identical (`diff -q` → `IDENTICAL`)
- [ ] Tell user it's ready to test in REAPER — do not claim verified
