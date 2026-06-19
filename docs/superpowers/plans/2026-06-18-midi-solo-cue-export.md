# MIDI Solo Cue Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create `GPhil_exportMidiSoloCue.lua` — export each selected MIDI item to a region/tempo-aware `.mid` file with the project's tempo and time-signature map embedded.

**Architecture:** Single-file, run-once Lua script. Read-only with respect to the project (no tempo map mutation, no undo block). Iterates selected items, resolves the containing region by time overlap, derives `$project`/`$region`/`$tempo`, reads the take's raw MIDI events via `MIDI_GetAllEvts`, merges in tempo/time-sig meta events converted from the project's tempo markers, and writes a format-0 Standard MIDI File.

**Tech Stack:** REAPER Lua API (stock, no SWS), Lua 5.1 string packing (`string.pack`/`string.unpack`), standard MIDI file format.

**Reference spec:** `docs/superpowers/specs/2026-06-18-midi-solo-cue-export-design.md`

**Conventions to follow:** Match `GPhil_createRegionsFromSelectedItemsTakeNames.lua` — `---@diagnostic disable-next-line: undefined-global`, `local reaper = reaper`, a `log()` helper, `main()` at the bottom.

---

## File Structure

**Single file:**
- Create: `GPhil_exportMidiSoloCue.lua` (repo root)
- Deploy-copy target: `/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/GPhil_exportMidiSoloCue.lua`

The file is organized top-to-bottom as: helpers → region/project/tempo resolution → MIDI building (event extraction, meta-event injection, SMF writer) → per-item export → main → deploy step. Because it is a single file and the functions are tightly coupled by the MIDI byte format, splitting into multiple files is not warranted.

**Note on TDD:** REAPER Lua scripts cannot be unit-tested outside REAPER (no `reaper` table available). The project has no test harness for Lua. Verification is by `luac -p` (syntax check) plus a manual smoke-test checklist the engineer runs in REAPER. Each task ends with `luac -p` and a commit; the final task has the manual smoke test.

---

## Task 1: Script skeleton + small helpers

**Files:**
- Create: `GPhil_exportMidiSoloCue.lua`

- [ ] **Step 1: Create the file with header, reaper local, and helpers**

Create `GPhil_exportMidiSoloCue.lua` with this exact content:

```lua
-- Export selected MIDI items to region/tempo-aware .mid files
-- with the project's tempo and time-signature map embedded.
-- Output path: AUDIO/SOLO_CUE/<region>/<project>_<region>_SOLO_CUE_<tempo>.mid

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local DIR_ROOT_REL = "AUDIO/SOLO_CUE"
local DIR_SEP = package.config:sub(1, 1) -- "/" on macOS/Windows Lua

local function log(msg)
    reaper.ShowConsoleMsg(tostring(msg) .. "\n")
end

-- Round to nearest integer; half rounds up. Used to kill float noise
-- like 59.999999 -> 60 in the filename tempo suffix.
local function round_tempo(tempo)
    return math.floor((tempo or 0) + 0.5)
end

-- Strip path and extension from a project filename.
local function get_project_stem(proj)
    local name = ""
    if reaper.GetProjectName then
        local ok, value = pcall(reaper.GetProjectName, proj, "")
        if ok and value then
            name = value
        end
    end

    name = name:match("([^/\\]+)$") or name
    name = name:gsub("%.[Rr][Pp][Pp]%-?[Bb]?[Aa]?[Kk]?$", "")
    name = name:gsub("%.[^%.]+$", "")
    if name == "" then
        name = "untitled"
    end
    return name
end

-- Replace characters illegal on macOS/Windows with _, collapse runs, trim ends.
local function sanitize_name_part(name)
    local text = name or ""
    text = text:gsub("[\t\r\n]", " ")
    text = text:gsub('[/\\:*?"<>|]', "_")
    text = text:gsub("%s+", " ")
    text = text:gsub("_+", "_")
    text = text:gsub("^[_%s]+", "")
    text = text:gsub("[_%s]+$", "")
    return text
end

local function main()
    local proj = 0
    log("=== GPhil MIDI Solo Cue Export ===")
    log("(stub)")
end

main()
```

- [ ] **Step 2: Syntax-check**

Run: `luac -p GPhil_exportMidiSoloCue.lua`
Expected: no output, exit code 0.

(If `luac` is not on PATH, install via `brew install lua`, or fall back to `lua -e 'assert(loadfile("GPhil_exportMidiSoloCue.lua"))'` which parses without executing.)

- [ ] **Step 3: Commit**

```bash
git add GPhil_exportMidiSoloCue.lua
git commit -m "Add skeleton for MIDI Solo Cue export script"
```

---

## Task 2: Region + tempo resolution

Add helpers that resolve, for a given item position, the containing region (smallest-`pos` wins on overlap) and the region's start BPM.

**Files:**
- Modify: `GPhil_exportMidiSoloCue.lua` (insert before `main`)

- [ ] **Step 1: Add region collection + overlap lookup**

Insert these functions immediately before `local function main()`:

```lua
-- Enumerate every region in the project as {pos, rgnend, name}.
local function collect_regions(proj)
    local regions = {}
    local idx = 0
    while true do
        local retval, is_region, pos, rgnend, name = reaper.EnumProjectMarkers3(proj, idx)
        if retval == 0 then
            break
        end
        if is_region then
            regions[#regions + 1] = {
                pos = pos,
                rgnend = rgnend,
                name = name or ""
            }
        end
        idx = idx + 1
    end
    return regions
end

-- Return the region whose [pos, rgnend] contains item_pos.
-- On overlap, the region with the smallest pos wins.
local function find_containing_region(regions, item_pos)
    local best
    for i = 1, #regions do
        local r = regions[i]
        if item_pos >= r.pos and item_pos <= r.rgnend then
            if not best or r.pos < best.pos then
                best = r
            end
        end
    end
    return best
end

-- Region's start BPM, read-only. Returns nil on failure.
local function region_start_bpm(proj, region)
    if not region then
        return nil
    end
    local bpm = reaper.TimeMap2_GetDividedBpmAtTime(proj, region.pos)
    if not bpm or bpm <= 0 then
        return nil
    end
    return bpm
end
```

- [ ] **Step 2: Syntax-check**

Run: `luac -p GPhil_exportMidiSoloCue.lua`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add GPhil_exportMidiSoloCue.lua
git commit -m "Add region/tempo resolution helpers"
```

---

## Task 3: MIDI event extraction

Walk `MIDI_GetAllEvts` into a flat list of events with absolute PPQ positions. This is the read side; the take is not modified.

**Files:**
- Modify: `GPhil_exportMidiSoloCue.lua`

- [ ] **Step 1: Add the extractor**

Insert before `local function main()`:

```lua
-- Extract the take's MIDI events into a list of
-- { ppq = absolute_ppq, msg = bytes_string, flags = int }.
-- Meta events (status 0xFF) are preserved as-is; they will be filtered
-- out before writing so only our injected tempo/timesig meta events remain.
local function extract_midi_events(take)
    local ok, midi_str = reaper.MIDI_GetAllEvts(take, "")
    if not ok then
        return nil
    end

    local events = {}
    local len = midi_str:len()
    local pos = 1
    local ppq = 0
    local unpack = string.unpack

    while pos <= len do
        local offset, flags, msg, next_pos = unpack("i4Bs4", midi_str, pos)
        ppq = ppq + offset
        events[#events + 1] = {
            ppq = ppq,
            flags = flags,
            msg = msg,
            is_meta = (msg:byte(1) == 0xFF)
        }
        pos = next_pos
    end

    return events
end
```

- [ ] **Step 2: Syntax-check**

Run: `luac -p GPhil_exportMidiSoloCue.lua`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add GPhil_exportMidiSoloCue.lua
git commit -m "Add MIDI event extraction from take"
```

---

## Task 4: Tempo/time-sig meta-event injection

Read project tempo markers in the region's span, convert each to a Set Tempo (`FF 51 03`) and Time Signature (`FF 58 04`) meta event at the take-relative PPQ, and merge into the event list.

**Files:**
- Modify: `GPhil_exportMidiSoloCue.lua`

- [ ] **Step 1: Add the marker collector**

Insert before `local function main()`:

```lua
-- Collect project tempo markers whose timepos (seconds) falls inside
-- [region.pos, region.rgnend].
local function collect_region_tempo_markers(proj, region)
    local out = {}
    local cnt = reaper.CountTempoTimeSigMarkers(proj)
    for i = 0, cnt - 1 do
        local retval, timepos, measurepos, beatpos, bpm,
              timesig_num, timesig_denom, lineartempo =
            reaper.GetTempoTimeSigMarker(proj, i)
        if retval and timepos >= region.pos and timepos <= region.rgnend then
            out[#out + 1] = {
                timepos = timepos,
                bpm = bpm,
                timesig_num = timesig_num,
                timesig_denom = timesig_denom
            }
        end
    end
    return out
end

-- Encode an unsigned integer as a 3-byte big-endian string.
local function u24_be(value)
    return string.char(
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF
    )
end

-- Build Set Tempo meta event bytes: FF 51 03 <mpqn_3_bytes>.
-- mpqn = microseconds per quarter note = 60000000 / bpm.
local function tempo_meta_msg(bpm)
    local mpqn = math.floor(60000000.0 / bpm + 0.5)
    return string.char(0xFF, 0x51, 0x03) .. u24_be(mpqn)
end

-- Build Time Signature meta event bytes: FF 58 04 nn dd cc bb.
-- dd = log2(denom). REAPER returns 0 for "default" numerator/denominator;
-- in that case treat it as 4/4 with standard MIDI clock values (24, 8).
local function timesig_meta_msg(num, denom)
    local nn = (num and num > 0) and num or 4
    local d = (denom and denom > 0) and denom or 4
    local dd = 0
    local v = d
    while v > 1 do
        v = v >> 1
        dd = dd + 1
    end
    -- cc = clocks per metronome click, bb = 32nd notes per 24 clocks.
    -- Standard defaults: 24 and 8.
    return string.char(0xFF, 0x58, 0x04, nn, dd, 24, 8)
end
```

- [ ] **Step 2: Add the merge function**

Insert immediately after `timesig_meta_msg`:

```lua
-- Merge tempo/time-sig meta events into the take's event list.
-- 1) Drop any existing meta events from the take (we own tempo/timesig).
-- 2) Convert each region tempo marker's timepos -> take-relative PPQ
--    via MIDI_GetPPQPosFromTime.
-- 3) Clamp markers that precede the take start to PPQ 0.
-- 4) Return a new list sorted by ascending ppq; meta events at the same
--    ppq as a note event sort BEFORE the note (standard SMF ordering).
local function merge_tempo_events(proj, take, events, region)
    local cleaned = {}
    for i = 1, #events do
        local e = events[i]
        if not e.is_meta then
            cleaned[#cleaned + 1] = e
        end
    end

    local markers = collect_region_tempo_markers(proj, region)
    local take_start_ppq = reaper.MIDI_GetPPQPosFromTime(take, region.pos)

    for i = 1, #markers do
        local m = markers[i]
        local ppq = reaper.MIDI_GetPPQPosFromTime(take, m.timepos)
        if ppq < take_start_ppq then
            ppq = take_start_ppq
        end

        if m.bpm and m.bpm > 0 then
            cleaned[#cleaned + 1] = {
                ppq = ppq,
                flags = 0,
                msg = tempo_meta_msg(m.bpm),
                is_meta = true,
                is_tempo = true
            }
        end

        cleaned[#cleaned + 1] = {
            ppq = ppq,
            flags = 0,
            msg = timesig_meta_msg(m.timesig_num, m.timesig_denom),
            is_meta = true,
            is_timesig = true
        }
    end

    table.sort(cleaned, function(a, b)
        if a.ppq ~= b.ppq then
            return a.ppq < b.ppq
        end
        -- Tempo first, then time signature, then note/CC events.
        local function rank(e)
            if e.is_tempo then return 0 end
            if e.is_timesig then return 1 end
            return 2
        end
        return rank(a) < rank(b)
    end)

    return cleaned
end
```

- [ ] **Step 3: Syntax-check**

Run: `luac -p GPhil_exportMidiSoloCue.lua`
Expected: no output, exit code 0.

- [ ] **Step 4: Commit**

```bash
git add GPhil_exportMidiSoloCue.lua
git commit -m "Add tempo/timesig meta-event injection"
```

---

## Task 5: Standard MIDI File writer

Take the merged event list and serialize a format-0 SMF: MThd header + MTrk chunk with variable-length delta encoding + end-of-track terminator.

**Files:**
- Modify: `GPhil_exportMidiSoloCue.lua`

- [ ] **Step 1: Add PPQ helper and SMF builder**

Insert before `local function main()`:

```lua
-- Compute the MIDI file's PPQ (ticks per quarter note) from the take.
-- Mirrors MPL's GetTakePPQ: map the item's time-start QN back to PPQ.
local function get_take_ppq(item, take)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local offset   = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local qn = reaper.TimeMap2_timeToQN(nil, position - offset)
    return reaper.MIDI_GetPPQPosFromProjQN(take, qn + 1)
end

-- Encode a non-negative integer as a MIDI variable-length quantity.
local function encode_varlen(value)
    local bytes = { value & 0x7F }
    value = value >> 7
    while value > 0 do
        bytes[#bytes + 1] = (value & 0x7F) | 0x80
        value = value >> 7
    end
    -- bytes were built LSB-first; reverse for output.
    local out = {}
    for i = #bytes, 1, -1 do
        out[#out + 1] = string.char(bytes[i])
    end
    return table.concat(out)
end

-- Build a complete format-0 SMF from the merged event list.
local function build_smf(events, ppq)
    -- Track body: for each event, varlen delta + raw message bytes.
    local body_parts = {}
    local last_ppq = 0
    for i = 1, #events do
        local e = events[i]
        local delta = e.ppq - last_ppq
        if delta < 0 then delta = 0 end
        body_parts[#body_parts + 1] = encode_varlen(delta)
        body_parts[#body_parts + 1] = e.msg
        last_ppq = e.ppq
    end

    -- End-of-track meta event: FF 2F 00 with zero delta.
    body_parts[#body_parts + 1] = string.char(0x00, 0xFF, 0x2F, 0x00)
    local body = table.concat(body_parts)

    -- MTrk header: 'MTrk' + 4-byte big-endian body length.
    local track_header = "MTrk"
        .. string.char(
            (body:len() >> 24) & 0xFF,
            (body:len() >> 16) & 0xFF,
            (body:len() >> 8) & 0xFF,
            body:len() & 0xFF
        )

    -- MThd header: format 0, 1 track, ppq ticks per quarter note.
    local main_header = "MThd"
        .. string.char(0x00, 0x00, 0x00, 0x06) -- header length = 6
        .. string.char(0x00, 0x00)             -- format 0
        .. string.char(0x00, 0x01)             -- 1 track
        .. string.char((ppq >> 8) & 0xFF, ppq & 0xFF)

    return main_header .. track_header .. body
end
```

- [ ] **Step 2: Syntax-check**

Run: `luac -p GPhil_exportMidiSoloCue.lua`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add GPhil_exportMidiSoloCue.lua
git commit -m "Add Standard MIDI File writer"
```

---

## Task 6: Per-item export + main loop

Wire everything together: iterate selected items, resolve region/tempo, build the SMF, create directories, write the file, log a summary.

**Files:**
- Modify: `GPhil_exportMidiSoloCue.lua` (replace the stub `main`)

- [ ] **Step 1: Replace `main` with the full implementation**

Replace the existing `local function main()` ... `main()` block (the stub from Task 1) with:

```lua
local function export_item(proj, item, regions, project_stem)
    local take = reaper.GetActiveTake(item)
    if not take then
        return "skip_no_take"
    end
    if not reaper.ValidatePtr2(proj, take, "MediaItem_Take*") then
        return "skip_no_take"
    end
    if not reaper.TakeIsMIDI(take) then
        return "warn_not_midi"
    end

    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local region = find_containing_region(regions, item_pos)
    if not region then
        return "skip_no_region"
    end

    local bpm = region_start_bpm(proj, region)
    if not bpm then
        return "skip_no_region"
    end

    local events = extract_midi_events(take)
    if not events then
        return "skip_no_take"
    end

    local merged = merge_tempo_events(proj, take, events, region)
    local ppq = get_take_ppq(item, take)
    local smf = build_smf(merged, ppq)

    local tempo_suffix = tostring(round_tempo(bpm))
    local region_name  = sanitize_name_part(region.name)
    if region_name == "" then
        region_name = "UNNAMED"
    end
    local proj_name    = sanitize_name_part(project_stem)

    local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)

    local rel_dir = DIR_ROOT_REL .. DIR_SEP .. region_name
    local filename = proj_name .. "_" .. region_name .. "_SOLO_CUE_" .. tempo_suffix .. ".mid"
    local out_dir  = reaper.GetProjectPath(proj) .. DIR_SEP .. rel_dir
    reaper.RecursiveCreateDirectory(out_dir, 0)

    local out_path = out_dir .. DIR_SEP .. filename
    local f = io.open(out_path, "wb")
    if not f then
        log("ERROR: could not open for write: " .. out_path)
        return "skip_no_take"
    end
    f:write(smf)
    f:close()

    log(string.format(
        "EXPORT: %s  (region=%s, tempo=%s, take=%s)",
        out_path, region_name, tempo_suffix, take_name or "<unnamed>"
    ))
    return "exported"
end

local function main()
    local proj = 0
    log("=== GPhil MIDI Solo Cue Export ===")

    local selected = reaper.CountSelectedMediaItems(proj)
    local project_stem = get_project_stem(proj)
    local regions = collect_regions(proj)
    local out_root = reaper.GetProjectPath(proj) .. DIR_SEP .. DIR_ROOT_REL

    log("Project: " .. project_stem)
    log("Output root: " .. out_root)
    log(string.format("Items selected: %d   Regions: %d", selected, #regions))
    log("--------------------------------------")

    local exported, skipped, warned = 0, 0, 0

    for i = 0, selected - 1 do
        local item = reaper.GetSelectedMediaItem(proj, i)
        local _, take_name
        local take = item and reaper.GetActiveTake(item) or nil
        if take then
            _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        end

        local result = export_item(proj, item, regions, project_stem)
        if result == "exported" then
            exported = exported + 1
        elseif result == "warn_not_midi" then
            warned = warned + 1
            log("WARN: skipping non-MIDI item: " .. (take_name or "<unnamed>"))
        elseif result == "skip_no_region" then
            skipped = skipped + 1
            log("SKIP: item has no containing region: " .. (take_name or "<unnamed>"))
        else
            skipped = skipped + 1
            log("SKIP: " .. (take_name or "<unnamed>"))
        end
    end

    log("--------------------------------------")
    log(string.format("Exported: %d   Skipped: %d   Warned: %d", exported, skipped, warned))
end

main()
```

- [ ] **Step 2: Syntax-check**

Run: `luac -p GPhil_exportMidiSoloCue.lua`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add GPhil_exportMidiSoloCue.lua
git commit -m "Wire up per-item export and main loop"
```

---

## Task 7: Deploy copy + manual smoke test

Per `AGENTS.md`: copy the edited script into the GPhil deployment folder and verify the copy matches. Then run a smoke test in REAPER.

**Files:**
- Read/verify: `/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/GPhil_exportMidiSoloCue.lua`

- [ ] **Step 1: Copy to deployment folder**

Run:

```bash
cp GPhil_exportMidiSoloCue.lua "/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/GPhil_exportMidiSoloCue.lua"
```

- [ ] **Step 2: Verify the copy matches the source**

Run:

```bash
diff -q GPhil_exportMidiSoloCue.lua "/Users/slav/Library/Application Support/REAPER/Scripts/GPhil/GPhil_exportMidiSoloCue.lua" && echo "MATCH" || echo "MISMATCH"
```

Expected output: `MATCH`.

- [ ] **Step 3: Manual smoke test in REAPER**

Open a REAPER project that has:
1. At least one region defined.
2. A tempo marker at the region's start (e.g. exactly 60 BPM — to confirm the float-noise rounding works, ideally one that REAPER stores as something like 59.999999).
3. One or more MIDI media items inside the region.

Steps:
1. Select one MIDI item inside the region.
2. Run the script via the Action List ("GPhil_exportMidiSoloCue" — may need to be loaded once).
3. Open the REAPER console (View → Console). Confirm:
   - `=== GPhil MIDI Solo Cue Export ===` header appears.
   - One `EXPORT:` line shows a path ending in `AUDIO/SOLO_CUE/<region>/<project>_<region>_SOLO_CUE_60.mid` (integer tempo, no decimals).
   - Summary line: `Exported: 1   Skipped: 0   Warned: 0`.
4. Drag the produced `.mid` into a new REAPER track (or any other DAW). Confirm:
   - It plays at 60 BPM, not 120 (tempo embedded correctly).
   - The tempo/time-signature lane shows the marker at the start.
5. Select an item that is NOT inside any region and re-run. Confirm a `SKIP:` line and `Skipped: 1` in the summary.
6. Select a non-MIDI (audio) item and re-run. Confirm a `WARN:` line and `Warned: 1` in the summary.
7. Confirm the project's own tempo map is unchanged after running (the script is read-only).

If any step fails, fix the script, re-syntax-check with `luac -p`, re-copy to the deployment folder, re-verify with `diff`, and re-test.

- [ ] **Step 4: Final commit (deployment note only — no repo change)**

The deployment folder is outside the repo, so there is nothing further to commit. Confirm `git status` shows a clean tree:

```bash
git status
```

Expected: `nothing to commit, working tree clean`.

---

## Self-Review

**Spec coverage:**
- Iterate selected items → Task 6 main loop. ✓
- `$region` via smallest-`pos` overlap → Task 2 `find_containing_region`. ✓
- `$project` via `GetProjectName`, extension stripped → Task 1 `get_project_stem`. ✓
- `$tempo` from region-start BPM, rounded integer → Task 2 `region_start_bpm` + Task 1 `round_tempo`. ✓
- Skip non-region items silently → Task 6 `skip_no_region` branch. ✓
- Warn on non-MIDI items → Task 6 `warn_not_midi` branch. ✓
- Overwrite existing files → Task 6 `io.open(... "wb")` truncates. ✓
- Path scheme `AUDIO/SOLO_CUE/<region>/<project>_<region>_SOLO_CUE_<tempo>.mid` → Task 6. ✓
- Sanitize name parts → Task 1 `sanitize_name_part`. ✓
- Format-0 SMF, PPQ from take → Task 5 `get_take_ppq` + `build_smf`. ✓
- Tempo markers as `FF 51 03`, mpqn = round(60000000/bpm) → Task 4 `tempo_meta_msg`. ✓
- Time sig as `FF 58 04`, dd = log2(denom), defaults 24/8 → Task 4 `timesig_meta_msg`. ✓
- Merge, sort, meta-before-notes at same PPQ → Task 4 `merge_tempo_events`. ✓
- Clamp earlier markers to PPQ start → Task 4 (the `if ppq < take_start_ppq` block). ✓
- No undo block, no defer, no GFX → Task 6 main is synchronous, no undo calls. ✓
- Console summary → Task 6 log lines. ✓
- Deploy + verify copy → Task 7. ✓

**Placeholder scan:** No TBD/TODO. Every step has concrete code or commands. ✓

**Type/name consistency:** `round_tempo`, `get_project_stem`, `sanitize_name_part`, `collect_regions`, `find_containing_region`, `region_start_bpm`, `extract_midi_events`, `collect_region_tempo_markers`, `u24_be`, `tempo_meta_msg`, `timesig_meta_msg`, `merge_tempo_events`, `get_take_ppq`, `encode_varlen`, `build_smf`, `export_item`, `main` — all referenced names are defined in earlier tasks, spellings consistent throughout. Event table keys (`ppq`, `flags`, `msg`, `is_meta`, `is_tempo`, `is_timesig`) match between extraction, merge, and write. ✓

No issues found.
