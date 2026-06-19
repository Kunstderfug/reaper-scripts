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

local function get_project_root(proj)
    local _, project_file = reaper.EnumProjects(proj, "")
    local root = nil
    if project_file and project_file ~= "" then
        root = project_file:match("^(.*)[/\\][^/\\]+$")
    end
    if not root or root == "" then
        root = reaper.GetProjectPath(proj)
    end
    if root then
        root = root:gsub("[/\\]+$", "")
        local parent = root:match("^(.*)[/\\][Mm][Ee][Dd][Ii][Aa]$")
        if parent and parent ~= "" then
            root = parent
        end
    end
    return root
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

-- Tolerance for floating-point drift at region boundaries. A position that
-- looks identical in the arrange view is routinely stored with sub-sample
-- drift (e.g. region pos 10.0 vs item D_POSITION 9.9999999), which would
-- make an exact >= / <= check wrongly reject an item sitting on the edge.
-- Matches the eps used in GPhil_tempoSet_render_gfx_direct.lua.
local REGION_EDGE_EPS = 0.0000005

-- Return the region whose [pos, rgnend] contains item_pos.
-- On overlap, the region with the smallest pos wins.
local function find_containing_region(regions, item_pos)
    local best
    for i = 1, #regions do
        local r = regions[i]
        if item_pos >= (r.pos - REGION_EDGE_EPS)
           and item_pos <= (r.rgnend + REGION_EDGE_EPS) then
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

-- Collect tempo/meter events for a region.
-- Always emit the active tempo/time signature at region.pos, even when the
-- project marker that defines it lives before the region. Then append explicit
-- tempo/time-signature markers inside the region.
local function collect_region_tempo_markers(proj, region)
    local out = {}
    local seen = {}

    local function append_event(timepos, bpm)
        local timesig_num, timesig_denom, active_tempo =
            reaper.TimeMap_GetTimeSigAtTime(proj, timepos)
        local event_bpm = (bpm and bpm > 0) and bpm or active_tempo
        if not event_bpm or event_bpm <= 0 then
            event_bpm = reaper.TimeMap2_GetDividedBpmAtTime(proj, timepos)
        end
        if not event_bpm or event_bpm <= 0 then
            return
        end

        local key = string.format("%.9f", timepos)
        if seen[key] then
            out[seen[key]] = {
                timepos = timepos,
                bpm = event_bpm,
                timesig_num = timesig_num,
                timesig_denom = timesig_denom
            }
            return
        end

        out[#out + 1] = {
            timepos = timepos,
            bpm = event_bpm,
            timesig_num = timesig_num,
            timesig_denom = timesig_denom
        }
        seen[key] = #out
    end

    append_event(region.pos, nil)

    local cnt = reaper.CountTempoTimeSigMarkers(proj)
    for i = 0, cnt - 1 do
        local retval, timepos, measurepos, beatpos, bpm,
              timesig_num, timesig_denom, lineartempo =
            reaper.GetTempoTimeSigMarker(proj, i)
        if retval
           and timepos > (region.pos + REGION_EDGE_EPS)
           and timepos <= (region.rgnend + REGION_EDGE_EPS) then
            append_event(timepos, bpm)
        end
    end

    table.sort(out, function(a, b)
        return a.timepos < b.timepos
    end)
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

-- Merge tempo/time-sig meta events into the take's event list.
-- 1) Drop any existing meta events from the take (we own tempo/timesig).
-- 2) Convert each region tempo marker's timepos -> take-relative PPQ
--    via MIDI_GetPPQPosFromProjTime.
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
    local take_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, region.pos)

    for i = 1, #markers do
        local m = markers[i]
        local ppq = reaper.MIDI_GetPPQPosFromProjTime(take, m.timepos)
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

-- Compute the MIDI file's PPQ (ticks per quarter note) from the take.
-- Mirrors MPL's GetTakePPQ: map the item's time-start QN back to PPQ.
local function get_take_ppq(item, take)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local offset   = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local qn = reaper.TimeMap2_timeToQN(nil, position - offset)
    return reaper.MIDI_GetPPQPosFromProjQN(take, qn + 1)
end

-- Encode a non-negative integer as a MIDI variable-length quantity.
-- value may arrive as a float (REAPER's MIDI_GetPPQPosFromProjTime returns
-- floating-point PPQ); round to nearest to minimize cumulative drift across
-- events, and floor at zero since deltas must be non-negative. Rounding
-- (rather than truncating) keeps later events from drifting systematically
-- early. Lua's bitwise operators reject non-integer floats, so the coercion
-- must happen before the first & / >>.
local function encode_varlen(value)
    if value < 0 then value = 0 end
    value = math.floor(value + 0.5)
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
    -- The SMF division field (ticks per quarter note) is an integer, but
    -- ppq arrives as a float from MIDI_GetPPQPosFromProjQN. Coerce once;
    -- Lua's bitwise operators reject non-integer floats.
    ppq = math.floor(ppq + 0.5)
    if ppq < 1 then ppq = 1 end

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
    local out_dir  = get_project_root(proj) .. DIR_SEP .. rel_dir
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
    local out_root = get_project_root(proj) .. DIR_SEP .. DIR_ROOT_REL

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
            local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            log(string.format(
                "SKIP: item has no containing region: %s  (item_pos=%.9f)",
                take_name or "<unnamed>", item_pos
            ))
        else
            skipped = skipped + 1
            log("SKIP: " .. (take_name or "<unnamed>"))
        end
    end

    log("--------------------------------------")
    log(string.format("Exported: %d   Skipped: %d   Warned: %d", exported, skipped, warned))
end

main()
