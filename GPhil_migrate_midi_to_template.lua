-- Migrate MIDI items from the current project into a new project based on a template.
--
-- Run this from the OLD project. The script prompts for:
--   1. Template .RPP file path
--   2. Output .RPP file path
--
-- It opens the template, copies tempo/time-signature markers, project markers/regions,
-- and MIDI item event data from old tracks to destination tracks with matching names.
-- Track FX/routing/envelopes from the old project are intentionally not copied.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local EXT_SECTION = "GPhilMigrateMidiToTemplate"

local function msg(text)
    reaper.ShowMessageBox(tostring(text), "Migrate MIDI to Template", 0)
end

local function log(text)
    reaper.ShowConsoleMsg(tostring(text) .. "\n")
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function normalize_track_name(name)
    name = trim(name or "")
    -- REAPER's default names like "Track 1" are not useful matching keys.
    return name:lower()
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function get_project_path(proj)
    local _, path = reaper.EnumProjects(proj, "")
    return path or ""
end

local function get_project_dir(path)
    return (path or ""):match("^(.*)[/\\]") or ""
end

local function suggest_output_path(old_path)
    if old_path == "" then
        return ""
    end

    local dir = get_project_dir(old_path)
    local name = old_path:match("([^/\\]+)$") or "migrated_project.rpp"
    local base = name:gsub("%.RPP$", ""):gsub("%.rpp$", "")
    if dir ~= "" then
        return dir .. "/" .. base .. "_template_migrated.rpp"
    end
    return base .. "_template_migrated.rpp"
end

local function prompt_paths(old_proj)
    local old_path = get_project_path(old_proj)
    local last_template = reaper.GetExtState(EXT_SECTION, "template_path")
    local last_output = reaper.GetExtState(EXT_SECTION, "output_path")

    if last_output == "" then
        last_output = suggest_output_path(old_path)
    end

    local ok, values = reaper.GetUserInputs(
        "Migrate MIDI to Template",
        2,
        "Template .RPP path,Output .RPP path",
        (last_template or "") .. "," .. (last_output or "")
    )

    if not ok then
        return nil, nil
    end

    local template_path, output_path = values:match("([^,]*),(.*)")
    template_path = trim(template_path)
    output_path = trim(output_path)

    if template_path == "" or output_path == "" then
        msg("Template and output paths are required.")
        return nil, nil
    end

    if not file_exists(template_path) then
        msg("Template file does not exist:\n\n" .. template_path)
        return nil, nil
    end

    if template_path:lower() == output_path:lower() then
        msg("Output path must be different from the template path so the template is not overwritten.")
        return nil, nil
    end

    if file_exists(output_path) then
        local overwrite = reaper.ShowMessageBox(
            "Output file already exists. Overwrite it?\n\n" .. output_path,
            "Migrate MIDI to Template",
            4
        )
        if overwrite ~= 6 then
            return nil, nil
        end
    end

    reaper.SetExtState(EXT_SECTION, "template_path", template_path, true)
    reaper.SetExtState(EXT_SECTION, "output_path", output_path, true)

    return template_path, output_path
end

local function get_track_name(track)
    local _, name = reaper.GetTrackName(track, "")
    return name or ""
end

local function capture_tempo_map(proj)
    local markers = {}
    local cnt = reaper.CountTempoTimeSigMarkers(proj)

    for i = 0, cnt - 1 do
        local retval, timepos, measurepos, beatpos, bpm, timesig_num, timesig_denom, lineartempo =
            reaper.GetTempoTimeSigMarker(proj, i)
        if retval then
            markers[#markers + 1] = {
                timepos = timepos,
                measurepos = measurepos,
                beatpos = beatpos,
                bpm = bpm,
                timesig_num = timesig_num,
                timesig_denom = timesig_denom,
                lineartempo = lineartempo
            }
        end
    end

    return markers
end

local function restore_tempo_map(proj, markers)
    for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do
        reaper.DeleteTempoTimeSigMarker(proj, i)
    end

    for i = 1, #markers do
        local m = markers[i]
        reaper.SetTempoTimeSigMarker(
            proj,
            -1,
            m.timepos,
            m.measurepos,
            m.beatpos,
            m.bpm,
            m.timesig_num,
            m.timesig_denom,
            m.lineartempo
        )
    end
end

local function capture_markers_and_regions(proj)
    local entries = {}
    local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
    local total = num_markers + num_regions

    for i = 0, total - 1 do
        local retval, is_region, pos, rgnend, name, markrgnindexnumber, color = reaper.EnumProjectMarkers3(proj, i)
        if retval then
            entries[#entries + 1] = {
                is_region = is_region,
                pos = pos,
                rgnend = rgnend,
                name = name or "",
                index = markrgnindexnumber,
                color = color or 0
            }
        end
    end

    return entries
end

local function restore_markers_and_regions(proj, entries)
    local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
    for i = num_markers + num_regions - 1, 0, -1 do
        local retval, is_region, _, _, _, index = reaper.EnumProjectMarkers3(proj, i)
        if retval then
            reaper.DeleteProjectMarker(proj, index, is_region)
        end
    end

    for i = 1, #entries do
        local e = entries[i]
        reaper.AddProjectMarker2(proj, e.is_region, e.pos, e.rgnend, e.name, e.index, e.color)
    end
end

local function capture_project_settings(proj)
    return {
        tempo = reaper.Master_GetTempo(),
        timebase = reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false),
        itemmix = reaper.GetSetProjectInfo(proj, "PROJECT_ITEMMIX", 0, false),
        metronome = reaper.GetSetProjectInfo(proj, "PROJECT_METRONOME", 0, false),
        loop = reaper.GetSetProjectInfo(proj, "PROJECT_LOOP", 0, false),
        sample_rate = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
    }
end

local function restore_project_settings(proj, settings)
    if settings.timebase then
        reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", settings.timebase, true)
    end
    if settings.itemmix then
        reaper.GetSetProjectInfo(proj, "PROJECT_ITEMMIX", settings.itemmix, true)
    end
    if settings.metronome then
        reaper.GetSetProjectInfo(proj, "PROJECT_METRONOME", settings.metronome, true)
    end
    if settings.loop then
        reaper.GetSetProjectInfo(proj, "PROJECT_LOOP", settings.loop, true)
    end
    if settings.sample_rate then
        reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", settings.sample_rate, true)
    end
    if settings.tempo then
        reaper.CSurf_OnTempoChange(settings.tempo)
    end
end

local function capture_midi_items(proj)
    local by_track_name = {}
    local duplicate_track_names = {}
    local skipped_audio = 0
    local captured = 0

    local track_count = reaper.CountTracks(proj)
    for track_index = 0, track_count - 1 do
        local track = reaper.GetTrack(proj, track_index)
        local track_name = get_track_name(track)
        local key = normalize_track_name(track_name)

        if key ~= "" then
            if by_track_name[key] then
                duplicate_track_names[key] = track_name
            end

            local bucket = by_track_name[key] or { display_name = track_name, items = {} }
            by_track_name[key] = bucket

            local item_count = reaper.CountTrackMediaItems(track)
            for item_index = 0, item_count - 1 do
                local item = reaper.GetTrackMediaItem(track, item_index)
                local take = reaper.GetActiveTake(item)

                if take and reaper.TakeIsMIDI(take) then
                    local ok, midi_events = reaper.MIDI_GetAllEvts(take, "")
                    if ok then
                        local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
                        bucket.items[#bucket.items + 1] = {
                            position = reaper.GetMediaItemInfo_Value(item, "D_POSITION"),
                            length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH"),
                            snap_offset = reaper.GetMediaItemInfo_Value(item, "D_SNAPOFFSET"),
                            fadein_len = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
                            fadeout_len = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
                            fadein_shape = reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE"),
                            fadeout_shape = reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE"),
                            mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE"),
                            lock = reaper.GetMediaItemInfo_Value(item, "C_LOCK"),
                            color = reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR"),
                            take_name = take_name or "",
                            midi_events = midi_events
                        }
                        captured = captured + 1
                    end
                else
                    skipped_audio = skipped_audio + 1
                end
            end
        end
    end

    return by_track_name, captured, skipped_audio, duplicate_track_names
end

local function build_destination_track_map(proj)
    local map = {}
    local duplicates = {}

    for i = 0, reaper.CountTracks(proj) - 1 do
        local track = reaper.GetTrack(proj, i)
        local name = get_track_name(track)
        local key = normalize_track_name(name)

        if key ~= "" then
            if map[key] then
                duplicates[key] = name
            else
                map[key] = track
            end
        end

        -- Track Manager visibility: make every template track visible in TCP and mixer.
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
        reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1)
    end

    return map, duplicates
end

local function apply_item_properties(item, data)
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", data.position)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", data.length)
    reaper.SetMediaItemInfo_Value(item, "D_SNAPOFFSET", data.snap_offset)
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", data.fadein_len)
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", data.fadeout_len)
    reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", data.fadein_shape)
    reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", data.fadeout_shape)
    reaper.SetMediaItemInfo_Value(item, "B_MUTE", data.mute)
    reaper.SetMediaItemInfo_Value(item, "C_LOCK", data.lock)
    reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", data.color)
end

local function clear_existing_items_on_matched_tracks(dest_items_by_name, dest_track_map)
    for key, source_track_data in pairs(dest_items_by_name) do
        local dest_track = dest_track_map[key]
        if dest_track and #source_track_data.items > 0 then
            for i = reaper.CountTrackMediaItems(dest_track) - 1, 0, -1 do
                local item = reaper.GetTrackMediaItem(dest_track, i)
                reaper.DeleteTrackMediaItem(dest_track, item)
            end
        end
    end
end

local function insert_midi_items(dest_proj, source_by_name, dest_track_map)
    local copied = 0
    local unmatched_tracks = {}

    for key, source_track_data in pairs(source_by_name) do
        local dest_track = dest_track_map[key]
        if dest_track then
            for i = 1, #source_track_data.items do
                local data = source_track_data.items[i]
                local item = reaper.CreateNewMIDIItemInProj(dest_track, data.position, data.position + data.length, false)
                local take = reaper.GetActiveTake(item)

                if item and take then
                    apply_item_properties(item, data)
                    reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", data.take_name, true)
                    reaper.MIDI_SetAllEvts(take, data.midi_events)
                    reaper.MIDI_Sort(take)
                    copied = copied + 1
                end
            end
        elseif #source_track_data.items > 0 then
            unmatched_tracks[#unmatched_tracks + 1] = source_track_data.display_name
        end
    end

    return copied, unmatched_tracks
end

local function list_duplicate_names(duplicates)
    local names = {}
    for _, display_name in pairs(duplicates) do
        names[#names + 1] = display_name
    end
    table.sort(names)
    return table.concat(names, "\n")
end

local function main()
    local old_proj = 0
    local old_path = get_project_path(old_proj)

    if old_path == "" then
        msg("Please save the old/source project before running this script.")
        return
    end

    local response = reaper.ShowMessageBox(
        "Run this from the OLD project.\n\n" ..
        "The script will open the selected template as the destination, copy MIDI item data to same-name tracks, " ..
        "copy tempo/time-signature markers and project markers/regions, make all template tracks visible, and save a new project.\n\n" ..
        "Old track FX/routing are NOT copied. Continue?",
        "Migrate MIDI to Template",
        4
    )

    if response ~= 6 then
        return
    end

    local template_path, output_path = prompt_paths(old_proj)
    if not template_path then
        return
    end

    reaper.Main_SaveProject(old_proj, false)

    local settings = capture_project_settings(old_proj)
    local tempo_map = capture_tempo_map(old_proj)
    local markers = capture_markers_and_regions(old_proj)
    local source_by_name, captured_count, skipped_non_midi_count, source_duplicates = capture_midi_items(old_proj)

    if captured_count == 0 then
        msg("No MIDI items were found in the source project.")
        return
    end

    reaper.PreventUIRefresh(1)

    -- Open the template in the current tab, then save it as the new output project.
    reaper.Main_openProject(template_path)
    local dest_proj = 0

    reaper.Undo_BeginBlock2(dest_proj)

    restore_project_settings(dest_proj, settings)
    restore_tempo_map(dest_proj, tempo_map)
    restore_markers_and_regions(dest_proj, markers)

    local dest_track_map, dest_duplicates = build_destination_track_map(dest_proj)
    clear_existing_items_on_matched_tracks(source_by_name, dest_track_map)
    local copied_count, unmatched_tracks = insert_midi_items(dest_proj, source_by_name, dest_track_map)

    reaper.UpdateArrange()
    reaper.Undo_EndBlock2(dest_proj, "Migrate MIDI items to template", -1)

    reaper.Main_SaveProjectEx(dest_proj, output_path, 0)
    reaper.PreventUIRefresh(-1)

    local report = {}
    report[#report + 1] = "Migration complete."
    report[#report + 1] = ""
    report[#report + 1] = "Output: " .. output_path
    report[#report + 1] = "MIDI items copied: " .. copied_count
    report[#report + 1] = "Non-MIDI/source items skipped: " .. skipped_non_midi_count
    report[#report + 1] = "Tempo/time-signature markers copied: " .. #tempo_map
    report[#report + 1] = "Project markers/regions copied: " .. #markers

    if #unmatched_tracks > 0 then
        table.sort(unmatched_tracks)
        report[#report + 1] = ""
        report[#report + 1] = "Source tracks with MIDI but no matching template track:"
        report[#report + 1] = table.concat(unmatched_tracks, "\n")
    end

    local source_duplicate_text = list_duplicate_names(source_duplicates)
    if source_duplicate_text ~= "" then
        report[#report + 1] = ""
        report[#report + 1] = "Warning: duplicate source track names were merged by name:"
        report[#report + 1] = source_duplicate_text
    end

    local dest_duplicate_text = list_duplicate_names(dest_duplicates)
    if dest_duplicate_text ~= "" then
        report[#report + 1] = ""
        report[#report + 1] =
        "Warning: duplicate destination track names exist. Only the first matching template track received MIDI:"
        report[#report + 1] = dest_duplicate_text
    end

    report[#report + 1] = ""
    report[#report + 1] =
    "Note: tempo and time-signature markers are copied via REAPER's API. If your old project uses custom metronome click patterns stored outside these markers, verify those manually in the migrated project."

    log(table.concat(report, "\n"))
    msg(table.concat(report, "\n"))
end

main()
