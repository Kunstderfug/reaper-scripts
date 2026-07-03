-- Generate timing-warp training variants from the selected SOLO MIDI item.
--
-- For each variant, the script:
--   1. Warps attack timings with a smooth random tempo curve.
--   2. Applies small note-on velocity variation.
--   3. Writes a performed MIDI sibling and timing-map JSON.
--   4. Queues an audio render of the same temporary performed MIDI.
--
-- Output:
--   STUDIO/analysis_workbench/ai/timing_warp_sources/<region>/performed/
--     <region>_perf_001_seed1234.mid
--     <region>_perf_001_seed1234_timing_map.json
--     <region>_perf_001_seed1234_solo_dry.<render extension>
--     <region>_perf_001_seed1234_solo_wet.<render extension>

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local ADD_TO_QUEUE_CMD = 41823 -- File: Add project to render queue, using the most recent render settings
local CMD_APPLY_SOLO_CUE = "_RSb6214dfe2bae78d7d897e42e57450017be87e017"

local EXT_SECTION = "gphilTimingWarpTraining"
local DEFAULT_VARIATION_COUNT = 15
local DEFAULT_TIMING_VARIATION_PCT = 10
local DEFAULT_VELOCITY_VARIATION_PCT = 8
local DEFAULT_SEED = 1729
local REGION_EDGE_EPS = 0.0000005
local MULTI_TRACK_TARGETS = {
    { track_name = "SOLO DRY", profile_suffix = "solo_dry" },
    { track_name = "SOLO WET", profile_suffix = "solo_wet" }
}

local RENDER_NUMERIC_KEYS = {
    "RENDER_SETTINGS",
    "RENDER_BOUNDSFLAG",
    "RENDER_CHANNELS",
    "RENDER_SRATE",
    "RENDER_STARTPOS",
    "RENDER_ENDPOS",
    "RENDER_TAILFLAG",
    "RENDER_TAILMS",
    "RENDER_ADDTOPROJ",
    "RENDER_DITHER",
    "RENDER_NORMALIZE",
    "RENDER_NORMALIZE_TARGET",
    "RENDER_BRICKWALL",
    "RENDER_FADEIN",
    "RENDER_FADEOUT",
    "RENDER_FADEINSHAPE",
    "RENDER_FADEOUTSHAPE",
    "RENDER_FADELPF",
    "RENDER_PADSTART",
    "RENDER_PADEND",
    "RENDER_TRIMSTART",
    "RENDER_TRIMEND",
    "RENDER_DELAY"
}

local RENDER_STRING_KEYS = {
    "RENDER_FILE",
    "RENDER_PATTERN",
    "RENDER_EXTRAFILEDIR",
    "RENDER_FORMAT",
    "RENDER_FORMAT2"
}

local function log(msg)
    reaper.ShowConsoleMsg(tostring(msg) .. "\n")
end

local function trim(value)
    return (value or ""):match("^%s*(.-)%s*$") or ""
end

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function sanitize_name_part(name)
    local text = name or ""
    text = text:gsub("[\t\r\n]", " ")
    text = text:gsub('[/\\:*?"<>|]', "_")
    text = text:gsub("%s+", "_")
    text = text:gsub("_+", "_")
    text = text:gsub("^[_%s]+", "")
    text = text:gsub("[_%s]+$", "")
    if text == "" then
        text = "UNNAMED"
    end
    return text
end

local function path_is_absolute(path)
    return path and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil)
end

local function join_path(left, right)
    if not left or left == "" then return right or "" end
    if not right or right == "" then return left end
    if path_is_absolute(right) then return right end
    return left:gsub("[/\\]+$", "") .. "/" .. right:gsub("^[/\\]+", "")
end

local function get_project_directory(proj)
    local _, project_file = reaper.EnumProjects(proj, "")
    local root = project_file and project_file:match("^(.*)[/\\][^/\\]+$") or nil
    if root and root ~= "" then
        return root:gsub("[/\\]+$", "")
    end
    if reaper.GetProjectPathEx then
        local ok, value = pcall(reaper.GetProjectPathEx, proj, "")
        if ok and value and value ~= "" then
            return value:gsub("[/\\]+$", "")
        end
    end
    local ok, value = pcall(reaper.GetProjectPath, "")
    if ok and value and value ~= "" then
        return value:gsub("[/\\]+$", "")
    end
    return ""
end

local function get_project_stem(proj)
    local name = ""
    if reaper.GetProjectName then
        local ok, value = pcall(reaper.GetProjectName, proj, "")
        if ok and value then name = value end
    end
    name = name:match("([^/\\]+)$") or name
    name = name:gsub("%.[Rr][Pp][Pp]%-?[Bb]?[Aa]?[Kk]?$", "")
    name = name:gsub("%.[^%.]+$", "")
    return sanitize_name_part(name ~= "" and name or "untitled")
end

local function capture_render_state(proj)
    local state = { numeric = {}, strings = {} }
    for i = 1, #RENDER_NUMERIC_KEYS do
        local key = RENDER_NUMERIC_KEYS[i]
        state.numeric[key] = reaper.GetSetProjectInfo(proj, key, 0, false)
    end
    for i = 1, #RENDER_STRING_KEYS do
        local key = RENDER_STRING_KEYS[i]
        local ok, value = reaper.GetSetProjectInfo_String(proj, key, "", false)
        if ok then state.strings[key] = value or "" end
    end
    return state
end

local function restore_render_state(proj, state)
    if not state then return end
    for i = 1, #RENDER_NUMERIC_KEYS do
        local key = RENDER_NUMERIC_KEYS[i]
        if state.numeric[key] ~= nil then
            reaper.GetSetProjectInfo(proj, key, state.numeric[key], true)
        end
    end
    for i = 1, #RENDER_STRING_KEYS do
        local key = RENDER_STRING_KEYS[i]
        if state.strings[key] ~= nil then
            reaper.GetSetProjectInfo_String(proj, key, state.strings[key], true)
        end
    end
end

local function capture_region_selection(proj)
    local snapshot = {}
    local total = reaper.GetNumRegionsOrMarkers(proj)
    for i = 0, total - 1 do
        local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
        if region_or_marker then
            local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
            if is_region then
                snapshot[#snapshot + 1] = {
                    internal_index = i,
                    selected = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL") > 0.5
                }
            end
        end
    end
    return snapshot
end

local function restore_region_selection(proj, snapshot)
    for i = 1, #(snapshot or {}) do
        local row = snapshot[i]
        local region_or_marker = reaper.GetRegionOrMarker(proj, row.internal_index, "")
        if region_or_marker then
            reaper.SetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL", row.selected and 1 or 0)
        end
    end
end

local function clear_all_region_selection(proj)
    local total = reaper.GetNumRegionsOrMarkers(proj)
    for i = 0, total - 1 do
        local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
        if region_or_marker then
            local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
            if is_region then
                reaper.SetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL", 0)
            end
        end
    end
end

local function select_only_track(track)
    reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
    if track then
        reaper.SetTrackSelected(track, true)
    end
end

local function get_track_name(track)
    local ok, name = reaper.GetTrackName(track, "")
    return ok and (name or "") or ""
end

local function find_track_by_name(proj, wanted_name)
    local wanted = (wanted_name or ""):lower()
    for i = 0, reaper.CountTracks(proj) - 1 do
        local track = reaper.GetTrack(proj, i)
        if get_track_name(track):lower() == wanted then
            return track
        end
    end
    return nil
end

local function track_render_suffix(track)
    local suffix = sanitize_name_part(get_track_name(track)):lower()
    if suffix == "" or suffix == "unnamed" then
        suffix = "track"
    end
    return suffix
end

local function find_midi_item_on_track_in_region(track, region, preferred_item)
    if preferred_item and reaper.GetMediaItemTrack(preferred_item) == track then
        return preferred_item, reaper.GetActiveTake(preferred_item)
    end

    local count = reaper.CountTrackMediaItems(track)
    for i = 0, count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local take = item and reaper.GetActiveTake(item) or nil
        if take and reaper.TakeIsMIDI(take) then
            local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            if pos >= (region.pos - REGION_EDGE_EPS) and pos <= (region.rgnend + REGION_EDGE_EPS) then
                return item, take
            end
        end
    end
    return nil, nil
end

local function resolve_command(cmd_id)
    if type(cmd_id) == "string" then
        local command = reaper.NamedCommandLookup(cmd_id)
        return command ~= 0 and command or nil
    end
    return cmd_id
end

local function apply_preset(cmd_id, label)
    local command = resolve_command(cmd_id)
    if not command or command == 0 then
        reaper.ShowMessageBox("Could not resolve render preset action for " .. label .. ".", "Error", 0)
        return false
    end
    reaper.Main_OnCommand(command, 0)
    return true
end

local function set_render_pattern(proj, pattern)
    reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", pattern or "", true)
end

local function commit_arrange()
    if reaper.UpdateTimeline then reaper.UpdateTimeline() end
    if reaper.UpdateArrange then reaper.UpdateArrange() end
end

local function selected_midi_item(proj)
    local selected = reaper.CountSelectedMediaItems(proj)
    if selected ~= 1 then
        return nil, "Select exactly one MIDI item on the SOLO track."
    end
    local item = reaper.GetSelectedMediaItem(proj, 0)
    local take = item and reaper.GetActiveTake(item) or nil
    if not take or not reaper.TakeIsMIDI(take) then
        return nil, "Selected item is not a MIDI item."
    end
    return item, take
end

local function get_region_name(proj, region_or_marker)
    local ok, name = reaper.GetSetRegionOrMarkerInfo_String(proj, region_or_marker, "P_NAME", "", false)
    if ok then return name or "" end
    return ""
end

local function containing_region_for_item(proj, item)
    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local best = nil
    local total = reaper.GetNumRegionsOrMarkers(proj)
    for i = 0, total - 1 do
        local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
        if region_or_marker then
            local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
            if is_region then
                local pos = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "D_STARTPOS")
                local rgnend = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "D_ENDPOS")
                if item_pos >= (pos - REGION_EDGE_EPS) and item_pos <= (rgnend + REGION_EDGE_EPS) then
                    if not best or pos < best.pos then
                        best = {
                            pos = pos,
                            rgnend = rgnend,
                            number = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "I_NUMBER"),
                            name = get_region_name(proj, region_or_marker)
                        }
                    end
                end
            end
        end
    end
    return best
end

local function read_midi_events(take)
    local ok, midi_str = reaper.MIDI_GetAllEvts(take, "")
    if not ok then return nil end
    local events = {}
    local ppq = 0
    local pos = 1
    while pos <= #midi_str do
        local offset, flags, msg, next_pos = string.unpack("i4Bs4", midi_str, pos)
        ppq = ppq + offset
        events[#events + 1] = {
            ppq = ppq,
            flags = flags,
            msg = msg
        }
        pos = next_pos
    end
    return events
end

local function event_kind(msg)
    local status = msg and msg:byte(1) or 0
    local kind = status & 0xF0
    if kind == 0x90 and (msg:byte(3) or 0) > 0 then return "note_on" end
    if kind == 0x80 or (kind == 0x90 and (msg:byte(3) or 0) == 0) then return "note_off" end
    return "other"
end

local function note_on_pitch(msg)
    if event_kind(msg) ~= "note_on" then return nil end
    return msg:byte(2)
end

local function scaled_note_velocity_msg(msg, factor)
    if event_kind(msg) ~= "note_on" then return msg end
    local status = msg:byte(1)
    local pitch = msg:byte(2)
    local velocity = msg:byte(3)
    local next_velocity = clamp(math.floor(velocity * factor + 0.5), 1, 127)
    if #msg > 3 then
        return string.char(status, pitch, next_velocity) .. msg:sub(4)
    end
    return string.char(status, pitch, next_velocity)
end

local function collect_attack_groups(events)
    local attacks = {}
    local by_ppq = {}
    for i = 1, #events do
        local pitch = note_on_pitch(events[i].msg)
        if pitch then
            local ppq_key = math.floor(events[i].ppq + 0.5)
            local group = by_ppq[ppq_key]
            if not group then
                group = { ppq = events[i].ppq, pitches = {} }
                by_ppq[ppq_key] = group
                attacks[#attacks + 1] = group
            end
            group.pitches[#group.pitches + 1] = pitch
        end
    end
    table.sort(attacks, function(a, b) return a.ppq < b.ppq end)
    for i = 1, #attacks do
        table.sort(attacks[i].pitches)
    end
    return attacks
end

local function lcg(seed)
    local state = math.floor(seed or DEFAULT_SEED) & 0x7FFFFFFF
    return function()
        state = (1103515245 * state + 12345) & 0x7FFFFFFF
        return state / 0x7FFFFFFF
    end
end

local function build_attack_warp(attacks, timing_pct, seed)
    local rand = lcg(seed)
    local max_delta = math.max(0, timing_pct or 0) / 100.0
    local warp = {}
    if #attacks == 0 then
        return warp
    end

    warp[1] = {
        attack_index = 1,
        reference_ppq = attacks[1].ppq,
        performed_ppq = attacks[1].ppq,
        local_stretch = 1.0,
        pitches = attacks[1].pitches
    }

    local performed_ppq = attacks[1].ppq
    local smooth = (rand() * 2 - 1) * max_delta * 0.35
    for i = 2, #attacks do
        local random_step = (rand() * 2 - 1) * max_delta
        smooth = smooth * 0.72 + random_step * 0.28
        local phrase_bias = math.sin((i - 1) / math.max(1, #attacks - 1) * math.pi) * max_delta * 0.18
        local stretch = clamp(1.0 + smooth + phrase_bias, 1.0 - max_delta, 1.0 + max_delta)
        local reference_delta = math.max(1, attacks[i].ppq - attacks[i - 1].ppq)
        performed_ppq = performed_ppq + reference_delta * stretch
        warp[i] = {
            attack_index = i,
            reference_ppq = attacks[i].ppq,
            performed_ppq = performed_ppq,
            local_stretch = stretch,
            pitches = attacks[i].pitches
        }
    end
    return warp
end

local function map_ppq(ppq, warp)
    if #warp == 0 then return ppq end
    if ppq <= warp[1].reference_ppq then
        return ppq + (warp[1].performed_ppq - warp[1].reference_ppq)
    end
    for i = 2, #warp do
        local prev = warp[i - 1]
        local cur = warp[i]
        if ppq <= cur.reference_ppq then
            local span = math.max(1, cur.reference_ppq - prev.reference_ppq)
            local t = (ppq - prev.reference_ppq) / span
            return prev.performed_ppq + t * (cur.performed_ppq - prev.performed_ppq)
        end
    end
    local last = warp[#warp]
    local prev = warp[math.max(1, #warp - 1)]
    local stretch = last.local_stretch or 1.0
    if last ~= prev and (last.reference_ppq - prev.reference_ppq) > 0 then
        stretch = (last.performed_ppq - prev.performed_ppq) / (last.reference_ppq - prev.reference_ppq)
    end
    return last.performed_ppq + (ppq - last.reference_ppq) * stretch
end

local function build_variant_events(events, warp, velocity_pct, seed)
    local rand = lcg(seed + 7919)
    local max_velocity_delta = math.max(0, velocity_pct or 0) / 100.0
    local out = {}
    for i = 1, #events do
        local event = events[i]
        local velocity_factor = 1.0
        if event_kind(event.msg) == "note_on" then
            velocity_factor = 1.0 + (rand() * 2 - 1) * max_velocity_delta
        end
        out[#out + 1] = {
            ppq = map_ppq(event.ppq, warp),
            flags = event.flags,
            msg = scaled_note_velocity_msg(event.msg, velocity_factor)
        }
    end
    table.sort(out, function(a, b)
        if a.ppq ~= b.ppq then return a.ppq < b.ppq end
        return event_kind(a.msg) < event_kind(b.msg)
    end)
    return out
end

local function encode_reaper_midi_events(events)
    local parts = {}
    local last_ppq = 0
    for i = 1, #events do
        local event = events[i]
        local ppq = math.max(0, math.floor(event.ppq + 0.5))
        local offset = ppq - last_ppq
        if offset < 0 then offset = 0 end
        parts[#parts + 1] = string.pack("i4Bs4", offset, event.flags or 0, event.msg or "")
        last_ppq = ppq
    end
    return table.concat(parts)
end

local function u24_be(value)
    return string.char((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
end

local function u32_be(value)
    return string.char((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
end

local function tempo_meta_msg(bpm)
    local mpqn = math.floor(60000000.0 / bpm + 0.5)
    return string.char(0xFF, 0x51, 0x03) .. u24_be(mpqn)
end

local function timesig_meta_msg(num, denom)
    local nn = (num and num > 0) and num or 4
    local d = (denom and denom > 0) and denom or 4
    local dd = 0
    local v = d
    while v > 1 do
        v = v >> 1
        dd = dd + 1
    end
    return string.char(0xFF, 0x58, 0x04, nn, dd, 24, 8)
end

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
        local retval, timepos, _, _, bpm = reaper.GetTempoTimeSigMarker(proj, i)
        if retval
           and timepos > (region.pos + REGION_EDGE_EPS)
           and timepos <= (region.rgnend + REGION_EDGE_EPS) then
            append_event(timepos, bpm)
        end
    end

    table.sort(out, function(a, b) return a.timepos < b.timepos end)
    return out
end

local function merge_tempo_events(proj, take, events, region)
    local cleaned = {}
    for i = 1, #events do
        local event = events[i]
        if (event.msg or ""):byte(1) ~= 0xFF then
            cleaned[#cleaned + 1] = event
        end
    end

    local markers = collect_region_tempo_markers(proj, region)
    local take_start_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, region.pos)

    for i = 1, #markers do
        local marker = markers[i]
        local marker_ppq = reaper.MIDI_GetPPQPosFromProjTime(take, marker.timepos)
        if marker_ppq < take_start_ppq then
            marker_ppq = take_start_ppq
        end

        cleaned[#cleaned + 1] = {
            ppq = marker_ppq,
            flags = 0,
            msg = tempo_meta_msg(marker.bpm),
            is_tempo = true
        }
        cleaned[#cleaned + 1] = {
            ppq = marker_ppq,
            flags = 0,
            msg = timesig_meta_msg(marker.timesig_num, marker.timesig_denom),
            is_timesig = true
        }
    end

    table.sort(cleaned, function(a, b)
        if a.ppq ~= b.ppq then return a.ppq < b.ppq end
        local function rank(event)
            if event.is_tempo then return 0 end
            if event.is_timesig then return 1 end
            return 2
        end
        return rank(a) < rank(b)
    end)

    return cleaned
end

local function encode_varlen(value)
    value = math.max(0, math.floor(value + 0.5))
    local bytes = { value & 0x7F }
    value = value >> 7
    while value > 0 do
        bytes[#bytes + 1] = (value & 0x7F) | 0x80
        value = value >> 7
    end
    local out = {}
    for i = #bytes, 1, -1 do
        out[#out + 1] = string.char(bytes[i])
    end
    return table.concat(out)
end

local function get_take_ppq(item, take)
    local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
    local qn = reaper.TimeMap2_timeToQN(nil, position - offset)
    local ppq = reaper.MIDI_GetPPQPosFromProjQN(take, qn + 1)
    return math.max(1, math.floor((ppq or 960) + 0.5))
end

local function build_smf(events, ppq)
    local body_parts = {}
    local last_ppq = 0
    for i = 1, #events do
        local event = events[i]
        local ppq_pos = math.max(0, math.floor(event.ppq + 0.5))
        body_parts[#body_parts + 1] = encode_varlen(ppq_pos - last_ppq)
        body_parts[#body_parts + 1] = event.msg
        last_ppq = ppq_pos
    end
    body_parts[#body_parts + 1] = string.char(0x00, 0xFF, 0x2F, 0x00)
    local body = table.concat(body_parts)
    local track_header = "MTrk" .. u32_be(#body)
    local main_header = "MThd"
        .. string.char(0x00, 0x00, 0x00, 0x06)
        .. string.char(0x00, 0x00)
        .. string.char(0x00, 0x01)
        .. string.char((ppq >> 8) & 0xFF, ppq & 0xFF)
    return main_header .. track_header .. body
end

local function write_file(path, content, mode)
    local file = io.open(path, mode or "wb")
    if not file then
        return false
    end
    file:write(content)
    file:close()
    return true
end

local function json_escape(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("\n", "\\n")
    text = text:gsub("\r", "\\r")
    text = text:gsub("\t", "\\t")
    return text
end

local function pitches_json(pitches)
    local out = {}
    for i = 1, #(pitches or {}) do
        out[#out + 1] = tostring(pitches[i])
    end
    return "[" .. table.concat(out, ", ") .. "]"
end

local function ppq_to_ms(ppq, ppq_per_quarter, bpm)
    return ppq / math.max(1, ppq_per_quarter) * (60000.0 / bpm)
end

local function write_timing_map(path, metadata)
    local lines = {}
    lines[#lines + 1] = "{"
    lines[#lines + 1] = '  "schemaVersion": 1,'
    lines[#lines + 1] = '  "datasetKind": "gphilTimingWarpSyntheticRender",'
    lines[#lines + 1] = '  "section": "' .. json_escape(metadata.section) .. '",'
    lines[#lines + 1] = '  "variantId": "' .. json_escape(metadata.variant_id) .. '",'
    lines[#lines + 1] = '  "midiPath": "' .. json_escape(metadata.midi_path) .. '",'
    lines[#lines + 1] = '  "audioStem": "' .. json_escape(metadata.audio_stem) .. '",'
    if metadata.audio_stems and #metadata.audio_stems > 0 then
        local stems = {}
        for i = 1, #metadata.audio_stems do
            stems[#stems + 1] = '"' .. json_escape(metadata.audio_stems[i]) .. '"'
        end
        lines[#lines + 1] = '  "audioStems": [' .. table.concat(stems, ", ") .. '],'
    end
    lines[#lines + 1] = string.format('  "baseTempoBpm": %.6f,', metadata.bpm)
    lines[#lines + 1] = string.format('  "timingVariationPct": %.6f,', metadata.timing_pct)
    lines[#lines + 1] = string.format('  "velocityVariationPct": %.6f,', metadata.velocity_pct)
    lines[#lines + 1] = string.format('  "seed": %d,', metadata.seed)
    lines[#lines + 1] = '  "timingPairs": ['
    for i = 1, #metadata.warp do
        local row = metadata.warp[i]
        local comma = i < #metadata.warp and "," or ""
        lines[#lines + 1] = string.format(
            '    { "attackIndex": %d, "referencePpq": %.3f, "performedPpq": %.3f, "referenceTimeMs": %.3f, "performedTimeMs": %.3f, "localStretch": %.6f, "pitches": %s }%s',
            row.attack_index,
            row.reference_ppq,
            row.performed_ppq,
            ppq_to_ms(row.reference_ppq - metadata.start_ppq, metadata.ppq, metadata.bpm),
            ppq_to_ms(row.performed_ppq - metadata.start_ppq, metadata.ppq, metadata.bpm),
            row.local_stretch or 1.0,
            pitches_json(row.pitches),
            comma
        )
    end
    lines[#lines + 1] = "  ]"
    lines[#lines + 1] = "}"
    return write_file(path, table.concat(lines, "\n") .. "\n", "w")
end

local function prompt_options(proj)
    local function last_num(key, fallback)
        local ok, value = reaper.GetProjExtState(proj, EXT_SECTION, key)
        return ok == 1 and tonumber(value) or fallback
    end

    local defaults = table.concat({
        tostring(last_num("variation_count", DEFAULT_VARIATION_COUNT)),
        tostring(last_num("timing_variation_pct", DEFAULT_TIMING_VARIATION_PCT)),
        tostring(last_num("velocity_variation_pct", DEFAULT_VELOCITY_VARIATION_PCT)),
        tostring(last_num("seed", DEFAULT_SEED))
    }, ",")

    local ok, csv = reaper.GetUserInputs(
        "Generate Timing-Warp Training Renders",
        4,
        "Variations,Timing +/- %,Velocity +/- %,Seed",
        defaults
    )
    if not ok then return nil end

    local cols = {}
    for value in (csv .. ","):gmatch("([^,]*),") do
        cols[#cols + 1] = trim(value)
    end

    local options = {
        variation_count = math.max(1, math.floor((tonumber(cols[1]) or DEFAULT_VARIATION_COUNT) + 0.5)),
        timing_variation_pct = clamp(tonumber(cols[2]) or DEFAULT_TIMING_VARIATION_PCT, 0, 40),
        velocity_variation_pct = clamp(tonumber(cols[3]) or DEFAULT_VELOCITY_VARIATION_PCT, 0, 40),
        seed = math.floor((tonumber(cols[4]) or DEFAULT_SEED) + 0.5)
    }

    reaper.SetProjExtState(proj, EXT_SECTION, "variation_count", tostring(options.variation_count))
    reaper.SetProjExtState(proj, EXT_SECTION, "timing_variation_pct", tostring(options.timing_variation_pct))
    reaper.SetProjExtState(proj, EXT_SECTION, "velocity_variation_pct", tostring(options.velocity_variation_pct))
    reaper.SetProjExtState(proj, EXT_SECTION, "seed", tostring(options.seed))
    return options
end

local function main()
    local proj = 0
    local item, take_or_error = selected_midi_item(proj)
    if not item then
        reaper.ShowMessageBox(take_or_error, "GPhil Timing-Warp Training", 0)
        return
    end
    local take = take_or_error
    local track = reaper.GetMediaItemTrack(item)
    local region = containing_region_for_item(proj, item)
    if not region then
        reaper.ShowMessageBox("Selected MIDI item must start inside a region.", "GPhil Timing-Warp Training", 0)
        return
    end
    local options = prompt_options(proj)
    if not options then return end

    local target_tracks = {}
    local all_named_targets_found = true
    for i = 1, #MULTI_TRACK_TARGETS do
        local spec = MULTI_TRACK_TARGETS[i]
        local candidate = find_track_by_name(proj, spec.track_name)
        if candidate then
            target_tracks[#target_tracks + 1] = {
                track = candidate,
                item = nil,
                take = nil,
                name = spec.track_name,
                profile_suffix = spec.profile_suffix
            }
        else
            all_named_targets_found = false
            break
        end
    end
    if not all_named_targets_found then
        target_tracks = {
            {
                track = track,
                item = item,
                take = take,
                name = get_track_name(track),
                profile_suffix = track_render_suffix(track)
            }
        }
    end

    for i = 1, #target_tracks do
        local target = target_tracks[i]
        local target_item, target_take = find_midi_item_on_track_in_region(target.track, region, item)
        if not target_item or not target_take then
            reaper.ShowMessageBox(
                "Could not find a MIDI item inside the selected region on track: " .. target.name,
                "GPhil Timing-Warp Training",
                0
            )
            return
        end
        target.item = target_item
        target.take = target_take
        target.original_mute = reaper.GetMediaTrackInfo_Value(target.track, "B_MUTE")
        target.original_length = reaper.GetMediaItemInfo_Value(target.item, "D_LENGTH")
        local target_midi_ok, target_midi = reaper.MIDI_GetAllEvts(target.take, "")
        if not target_midi_ok then
            reaper.ShowMessageBox("Could not read MIDI take on track: " .. target.name, "GPhil Timing-Warp Training", 0)
            return
        end
        target.original_midi = target_midi
    end

    local original_midi_ok, original_midi = reaper.MIDI_GetAllEvts(take, "")
    if not original_midi_ok then
        reaper.ShowMessageBox("Could not read selected MIDI take.", "GPhil Timing-Warp Training", 0)
        return
    end
    local original_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local original_render_state = capture_render_state(proj)
    local original_region_selection = capture_region_selection(proj)
    local original_selected_tracks = {}
    for i = 0, reaper.CountTracks(proj) - 1 do
        local candidate = reaper.GetTrack(proj, i)
        if reaper.IsTrackSelected(candidate) then
            original_selected_tracks[#original_selected_tracks + 1] = candidate
        end
    end

    local events = read_midi_events(take)
    local attacks = events and collect_attack_groups(events) or {}
    if not events or #attacks < 2 then
        reaper.ShowMessageBox("Selected MIDI item needs at least two note attacks.", "GPhil Timing-Warp Training", 0)
        return
    end

    local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local bpm = reaper.TimeMap2_GetDividedBpmAtTime(proj, item_pos)
    if not bpm or bpm <= 0 then bpm = 60 end
    local ppq = get_take_ppq(item, take)
    local section_name = sanitize_name_part(region.name ~= "" and region.name or tostring(region.number or "section"))
    local project_root = get_project_directory(proj)
    local out_dir = join_path(project_root, "STUDIO/analysis_workbench/ai/timing_warp_sources/" .. section_name .. "/performed")
    reaper.RecursiveCreateDirectory(out_dir, 0)

    reaper.Undo_BeginBlock()
    reaper.ShowConsoleMsg("")
    log("=== GPhil Timing-Warp Training Render Generator ===")
    log("Section: " .. section_name)
    log("Output: " .. out_dir)
    log(string.format(
        "Variations: %d, timing +/- %.2f%%, velocity +/- %.2f%%",
        options.variation_count,
        options.timing_variation_pct,
        options.velocity_variation_pct
    ))
    if #target_tracks > 1 then
        local names = {}
        for i = 1, #target_tracks do
            names[#names + 1] = target_tracks[i].name
        end
        log("Render targets: " .. table.concat(names, ", "))
    end
    log("--------------------------------------")

    local temp_region_indices = {}
    local queued = 0
    local midi_written = 0
    local maps_written = 0

    local function restore_original_state()
        for i = 1, #target_tracks do
            local target = target_tracks[i]
            reaper.MIDI_SetAllEvts(target.take, target.original_midi)
            reaper.MIDI_Sort(target.take)
            reaper.SetMediaItemInfo_Value(target.item, "D_LENGTH", target.original_length)
            if target.original_mute ~= nil then
                reaper.SetMediaTrackInfo_Value(target.track, "B_MUTE", target.original_mute)
            end
        end
        if #target_tracks == 0 then
            reaper.MIDI_SetAllEvts(take, original_midi)
            reaper.MIDI_Sort(take)
            reaper.SetMediaItemInfo_Value(item, "D_LENGTH", original_length)
        end
        restore_render_state(proj, original_render_state)
        restore_region_selection(proj, original_region_selection)
        reaper.Main_OnCommand(40297, 0)
        for i = 1, #original_selected_tracks do
            reaper.SetTrackSelected(original_selected_tracks[i], true)
        end
        for i = #temp_region_indices, 1, -1 do
            reaper.DeleteProjectMarker(proj, temp_region_indices[i], true)
        end
        commit_arrange()
    end

    local function format_traceback(err)
        if debug and debug.traceback then
            return debug.traceback(tostring(err), 2)
        end
        return tostring(err)
    end

    local ok, err = xpcall(function()
        if not apply_preset(CMD_APPLY_SOLO_CUE, "SOLO_CUE") then
            return
        end

        for variant_index = 1, options.variation_count do
            local variant_seed = options.seed + variant_index * 101
            local warp = build_attack_warp(attacks, options.timing_variation_pct, variant_seed)
            local variant_events = build_variant_events(events, warp, options.velocity_variation_pct, variant_seed)
            local midi_blob = encode_reaper_midi_events(variant_events)
            for target_index = 1, #target_tracks do
                local target = target_tracks[target_index]
                reaper.MIDI_SetAllEvts(target.take, midi_blob)
                reaper.MIDI_Sort(target.take)
            end

            local last_ppq = 0
            for i = 1, #variant_events do
                if variant_events[i].ppq > last_ppq then
                    last_ppq = variant_events[i].ppq
                end
            end
            local performed_length = ppq_to_ms(last_ppq, ppq, bpm) / 1000.0
            performed_length = math.max(0.25, performed_length + 0.25)
            for target_index = 1, #target_tracks do
                reaper.SetMediaItemInfo_Value(target_tracks[target_index].item, "D_LENGTH", performed_length)
            end

            local variant_id = string.format("perf_%03d_seed%d", variant_index, variant_seed)
            local base_stem = section_name .. "_" .. variant_id
            local audio_stems = {}
            for target_index = 1, #target_tracks do
                audio_stems[target_index] = section_name .. "_" .. variant_id .. "_" .. target_tracks[target_index].profile_suffix
            end
            local audio_stem = audio_stems[1]
            local midi_path = join_path(out_dir, base_stem .. ".mid")
            local map_path = join_path(out_dir, section_name .. "_" .. variant_id .. "_timing_map.json")
            local merged_events = merge_tempo_events(proj, take, variant_events, region)
            local smf = build_smf(merged_events, ppq)
            if write_file(midi_path, smf, "wb") then
                midi_written = midi_written + 1
            else
                log("ERROR: could not write MIDI: " .. midi_path)
            end
            if write_timing_map(map_path, {
                section = section_name,
                variant_id = variant_id,
                midi_path = midi_path,
                audio_stem = audio_stem,
                audio_stems = audio_stems,
                bpm = bpm,
                timing_pct = options.timing_variation_pct,
                velocity_pct = options.velocity_variation_pct,
                seed = variant_seed,
                warp = warp,
                ppq = ppq,
                start_ppq = attacks[1].ppq
            }) then
                maps_written = maps_written + 1
            else
                log("ERROR: could not write timing map: " .. map_path)
            end

            clear_all_region_selection(proj)
            local temp_region_name = audio_stem
            local marker_index = reaper.AddProjectMarker2(
                proj,
                true,
                item_pos,
                item_pos + performed_length,
                temp_region_name,
                -1,
                0
            )
            temp_region_indices[#temp_region_indices + 1] = marker_index
            local total = reaper.GetNumRegionsOrMarkers(proj)
            for i = 0, total - 1 do
                local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
                if region_or_marker then
                    local number = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "I_NUMBER")
                    if number == marker_index then
                        reaper.SetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL", 1)
                    end
                end
            end

            for target_index = 1, #target_tracks do
                local target = target_tracks[target_index]
                local target_audio_stem = audio_stems[target_index]
                restore_render_state(proj, original_render_state)
                apply_preset(CMD_APPLY_SOLO_CUE, "SOLO_CUE")
                set_render_pattern(proj, "STUDIO/analysis_workbench/ai/timing_warp_sources/" .. section_name .. "/performed/" .. target_audio_stem)
                reaper.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 5, true)
                select_only_track(target.track)
                reaper.SetMediaTrackInfo_Value(target.track, "B_MUTE", 0)
                commit_arrange()
                reaper.Main_OnCommand(ADD_TO_QUEUE_CMD, 0)
                queued = queued + 1
                log(string.format("QUEUED %s (%s)", target_audio_stem, target.name))
            end
        end
    end, format_traceback)

    restore_original_state()
    reaper.Undo_EndBlock("Generate timing-warp training renders", -1)

    if not ok then
        reaper.ShowMessageBox("Generation failed:\n" .. tostring(err), "GPhil Timing-Warp Training", 0)
        log("ERROR: " .. tostring(err))
        return
    end

    log("--------------------------------------")
    log(string.format("MIDI files: %d, timing maps: %d, queued audio renders: %d", midi_written, maps_written, queued))
    log("Open REAPER Render Queue to run the queued audio renders.")
end

main()
