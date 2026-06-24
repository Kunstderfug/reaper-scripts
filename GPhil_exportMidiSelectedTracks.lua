-- Export selected MIDI items within the selected region to one MIDI file per source track.
-- Output path: AUDIO/<tracknumber>_<project>_<trackname>.mid

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local DIR_ROOT_REL = "AUDIO"
local DIR_SEP = package.config:sub(1, 1) -- "/" on macOS/Windows Lua

local function log(msg)
    reaper.ShowConsoleMsg(tostring(msg) .. "\n")
end

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
    local function directory_from_project_file(project_file)
        if not project_file or project_file == "" then
            return nil
        end
        if not project_file:match("%.[Rr][Pp][Pp]%-?[Bb]?[Aa]?[Kk]?$") then
            return nil
        end
        return project_file:match("^(.*)[/\\][^/\\]+$")
    end

    local _, project_file = reaper.EnumProjects(-1, "")
    local root = directory_from_project_file(project_file)

    if not root or root == "" then
        _, project_file = reaper.EnumProjects(proj, "")
        root = directory_from_project_file(project_file)
    end

    if root then
        return root:gsub("[/\\]+$", "")
    end

    if reaper.GetProjectPathEx then
        local ok, value = pcall(reaper.GetProjectPathEx, proj, "")
        if ok and value and value ~= "" then
            return value:gsub("[/\\]+$", "")
        end
    end

    if reaper.GetProjectPath then
        local ok, value = pcall(reaper.GetProjectPath, "")
        if ok and value and value ~= "" then
            return value:gsub("[/\\]+$", "")
        end
    end

    return nil
end

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

local function u24_be(value)
    return string.char(
        (value >> 16) & 0xFF,
        (value >> 8) & 0xFF,
        value & 0xFF
    )
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

local function encode_varlen(value)
    if value < 0 then value = 0 end
    value = math.floor(value + 0.5)
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

local function get_project_ppq(proj)
    local track_count = reaper.CountTracks(proj)
    for track_idx = 0, track_count - 1 do
        local track = reaper.GetTrack(proj, track_idx)
        local item_count = reaper.CountTrackMediaItems(track)
        for item_idx = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, item_idx)
            local take = item and reaper.GetActiveTake(item) or nil
            if take and reaper.TakeIsMIDI(take) then
                local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                local offset = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
                local qn = reaper.TimeMap2_timeToQN(proj, position - offset)
                local ppq = reaper.MIDI_GetPPQPosFromProjQN(take, qn + 1)
                if ppq and ppq > 0 then
                    return math.floor(ppq + 0.5)
                end
            end
        end
    end
    return 960
end

local function project_time_to_region_ppq(proj, timepos, region, ppq)
    local qn = reaper.TimeMap2_timeToQN(proj, timepos)
    local region_qn = reaper.TimeMap2_timeToQN(proj, region.pos)
    return (qn - region_qn) * ppq
end

local function get_region_name(proj, region_or_marker)
    local ok, name = reaper.GetSetRegionOrMarkerInfo_String(proj, region_or_marker, "P_NAME", "", false)
    if ok then
        return name or ""
    end
    return ""
end

local function collect_selected_regions(proj)
    local regions = {}
    local total = reaper.GetNumRegionsOrMarkers(proj)
    for i = 0, total - 1 do
        local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
        if region_or_marker then
            local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
            local selected = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL") > 0.5
            if is_region and selected then
                regions[#regions + 1] = {
                    pos = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "D_STARTPOS"),
                    rgnend = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "D_ENDPOS"),
                    name = get_region_name(proj, region_or_marker)
                }
            end
        end
    end

    table.sort(regions, function(a, b)
        return a.pos < b.pos
    end)

    return regions
end

local REGION_EDGE_EPS = 0.0000005

local function time_is_inside_region(timepos, region)
    return timepos >= (region.pos - REGION_EDGE_EPS)
        and timepos <= (region.rgnend + REGION_EDGE_EPS)
end

local function item_overlaps_region(item, region)
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local item_end = pos + length
    return item_end >= (region.pos - REGION_EDGE_EPS)
        and pos <= (region.rgnend + REGION_EDGE_EPS)
end

local function collect_project_tempo_events(proj, ppq, region)
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
        local event = {
            timepos = timepos,
            ppq = project_time_to_region_ppq(proj, timepos, region, ppq),
            bpm = event_bpm,
            timesig_num = timesig_num,
            timesig_denom = timesig_denom
        }

        if seen[key] then
            out[seen[key]] = event
            return
        end

        out[#out + 1] = event
        seen[key] = #out
    end

    append_event(region.pos, nil)

    local cnt = reaper.CountTempoTimeSigMarkers(proj)
    for i = 0, cnt - 1 do
        local retval, timepos, _, _, bpm =
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
        if msg and msg ~= "" and msg:byte(1) ~= 0xFF then
            events[#events + 1] = {
                ppq = ppq,
                flags = flags,
                msg = msg
            }
        end
        pos = next_pos
    end

    return events
end

local function collect_selected_track_midi_events(proj, track, region, ppq)
    local out = {}
    local selected_item_count = reaper.CountSelectedMediaItems(proj)
    local midi_item_count = 0

    for item_idx = 0, selected_item_count - 1 do
        local item = reaper.GetSelectedMediaItem(proj, item_idx)
        if item
            and reaper.GetMediaItemTrack(item) == track
            and item_overlaps_region(item, region) then
            local take = reaper.GetActiveTake(item)
            if take
                and reaper.ValidatePtr2(proj, take, "MediaItem_Take*")
                and reaper.TakeIsMIDI(take) then
                local events = extract_midi_events(take)
                if events then
                    midi_item_count = midi_item_count + 1
                    for i = 1, #events do
                        local event = events[i]
                        local timepos = reaper.MIDI_GetProjTimeFromPPQPos(take, event.ppq)
                        if time_is_inside_region(timepos, region) then
                            out[#out + 1] = {
                                ppq = project_time_to_region_ppq(proj, timepos, region, ppq),
                                flags = event.flags,
                                msg = event.msg,
                                is_meta = false
                            }
                        end
                    end
                end
            end
        end
    end

    return out, midi_item_count
end

local function collect_tracks_from_selected_midi_items(proj, region)
    local tracks = {}
    local seen = {}
    local selected_item_count = reaper.CountSelectedMediaItems(proj)

    for item_idx = 0, selected_item_count - 1 do
        local item = reaper.GetSelectedMediaItem(proj, item_idx)
        local track = item and reaper.GetMediaItemTrack(item) or nil
        local take = item and reaper.GetActiveTake(item) or nil
        if track
            and item_overlaps_region(item, region)
            and take
            and reaper.ValidatePtr2(proj, take, "MediaItem_Take*")
            and reaper.TakeIsMIDI(take)
            and not seen[track] then
            tracks[#tracks + 1] = track
            seen[track] = true
        end
    end

    table.sort(tracks, function(a, b)
        return reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER")
            < reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
    end)

    return tracks
end

local function build_smf(events, ppq)
    ppq = math.floor(ppq + 0.5)
    if ppq < 1 then ppq = 1 end

    table.sort(events, function(a, b)
        if a.ppq ~= b.ppq then
            return a.ppq < b.ppq
        end
        local function rank(e)
            if e.is_tempo then return 0 end
            if e.is_timesig then return 1 end
            return 2
        end
        return rank(a) < rank(b)
    end)

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

    body_parts[#body_parts + 1] = string.char(0x00, 0xFF, 0x2F, 0x00)
    local body = table.concat(body_parts)

    local track_header = "MTrk"
        .. string.char(
            (body:len() >> 24) & 0xFF,
            (body:len() >> 16) & 0xFF,
            (body:len() >> 8) & 0xFF,
            body:len() & 0xFF
        )

    local main_header = "MThd"
        .. string.char(0x00, 0x00, 0x00, 0x06)
        .. string.char(0x00, 0x00)
        .. string.char(0x00, 0x01)
        .. string.char((ppq >> 8) & 0xFF, ppq & 0xFF)

    return main_header .. track_header .. body
end

local function export_track(proj, track, region, project_stem, out_dir, ppq)
    local track_number = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER") + 0.5)
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    track_name = sanitize_name_part(track_name)
    if track_name == "" then
        track_name = "Track " .. tostring(track_number)
    end

    local events, midi_item_count = collect_selected_track_midi_events(proj, track, region, ppq)
    if #events == 0 then
        return "skip_no_midi", track_number, track_name, midi_item_count
    end

    local tempo_events = collect_project_tempo_events(proj, ppq, region)
    for i = 1, #tempo_events do
        local marker = tempo_events[i]
        events[#events + 1] = {
            ppq = marker.ppq,
            flags = 0,
            msg = tempo_meta_msg(marker.bpm),
            is_meta = true,
            is_tempo = true
        }
        events[#events + 1] = {
            ppq = marker.ppq,
            flags = 0,
            msg = timesig_meta_msg(marker.timesig_num, marker.timesig_denom),
            is_meta = true,
            is_timesig = true
        }
    end

    local filename = tostring(track_number) .. "_"
        .. sanitize_name_part(project_stem) .. "_"
        .. track_name .. ".mid"
    local out_path = out_dir .. DIR_SEP .. filename

    local f = io.open(out_path, "wb")
    if not f then
        log("ERROR: could not open for write: " .. out_path)
        return "skip_write_failed", track_number, track_name, midi_item_count
    end
    f:write(build_smf(events, ppq))
    f:close()

    log(string.format(
        "EXPORT: %s  (track=%d, region=%s, selected_midi_items=%d)",
        out_path, track_number, region.name or "", midi_item_count
    ))
    return "exported", track_number, track_name, midi_item_count
end

local function main()
    local proj = 0
    log("=== GPhil MIDI Selected Items Export ===")

    local selected_items = reaper.CountSelectedMediaItems(proj)
    local project_stem = get_project_stem(proj)
    local project_root = get_project_root(proj)
    local selected_regions = collect_selected_regions(proj)
    if not project_root or project_root == "" then
        reaper.ShowMessageBox("Could not determine project root.", "GPhil MIDI Selected Items Export", 0)
        return
    end

    local out_dir = project_root .. DIR_SEP .. DIR_ROOT_REL
    local ppq = get_project_ppq(proj)

    log("Project: " .. project_stem)
    log("Output root: " .. out_dir)
    log(string.format("Regions selected: %d   Items selected: %d   PPQ: %d", #selected_regions, selected_items, ppq))
    log("--------------------------------------")

    if selected_items == 0 then
        reaper.ShowMessageBox("Select one or more MIDI items to export.", "GPhil MIDI Selected Items Export", 0)
        return
    end

    if #selected_regions == 0 then
        reaper.ShowMessageBox("Select one region to define the MIDI export range.", "GPhil MIDI Selected Items Export", 0)
        return
    end

    if #selected_regions > 1 then
        reaper.ShowMessageBox("Select exactly one region for this MIDI export.", "GPhil MIDI Selected Items Export", 0)
        return
    end

    local region = selected_regions[1]
    local tracks = collect_tracks_from_selected_midi_items(proj, region)
    log(string.format(
        "Region: %s  (%.9f - %.9f)   MIDI item tracks in region: %d",
        region.name or "",
        region.pos,
        region.rgnend,
        #tracks
    ))

    if #tracks == 0 then
        reaper.ShowMessageBox("Selected items do not contain MIDI takes inside the selected region.", "GPhil MIDI Selected Items Export", 0)
        return
    end

    reaper.RecursiveCreateDirectory(out_dir, 0)

    local exported, skipped = 0, 0
    for i = 1, #tracks do
        local track = tracks[i]
        local result, track_number, track_name = export_track(proj, track, region, project_stem, out_dir, ppq)
        if result == "exported" then
            exported = exported + 1
        else
            skipped = skipped + 1
            log(string.format(
                "SKIP: track %s %s (%s)",
                tostring(track_number or "?"),
                track_name or "<unnamed>",
                result
            ))
        end
    end

    log("--------------------------------------")
    log(string.format("Exported: %d   Skipped: %d", exported, skipped))

    reaper.ShowMessageBox(
        string.format(
            "MIDI export complete.\n\nExported: %d\nSkipped: %d\n\nOutput folder:\n%s",
            exported,
            skipped,
            out_dir
        ),
        "GPhil MIDI Selected Items Export",
        0
    )
end

main()
