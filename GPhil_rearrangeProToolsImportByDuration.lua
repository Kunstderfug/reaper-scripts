-- GPhil_rearrangeProToolsImportByDuration.lua
-- Group Pro Tools import items by identical duration into event clusters, then lay
-- those events out chronologically by source-file recorded time (birthtime, else
-- mtime). Map Audio N / named sources onto canonical mic tracks, hard-pan L/R,
-- Save As a copy.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local EXT_SECTION = "GPhilRearrangeProToolsImportByDuration"
local SCRIPT_TITLE = "Rearrange Pro Tools Import By Duration"
local DURATION_EPS = 0.001 -- 1 ms clustering tolerance
local REGION_GAP = 60.0 -- seconds between event regions
local STAT_BIN = "/usr/bin/stat"
-- When false, keep every item (including silent files); user deletes manually.
local SKIP_SILENT = false
-- Treat as silent if max peak is at or below this (dBFS). Used only when SKIP_SILENT.
local SILENCE_PEAK_DB = -60.0

-- Canonical destination tracks in preferred create order.
local CANONICAL_TRACK_ORDER = {
    "PNO_1_L",
    "PNO_1_R",
    "PNO_2_L",
    "PNO_2_R",
    "PNO_MAIN_L",
    "PNO_MAIN_R",
    "HOUSE_L",
    "HOUSE_R",
    "CENTER",
    "AMB_L",
    "AMB_R",
}

-- Audio N → canonical track (unmapped N stays "Audio N").
local AUDIO_NUM_TO_TRACK = {
    [1] = "PNO_1_R",
    [2] = "PNO_1_L",
    [3] = "PNO_2_L",
    [4] = "PNO_2_R",
    [5] = "PNO_MAIN_L",
    [6] = "PNO_MAIN_R",
    [7] = "HOUSE_L",
    [8] = "HOUSE_R",
    [13] = "CENTER",
    [27] = "AMB_L",
    [28] = "AMB_R",
}

-- Hard pan by destination track name (*_L → -1, *_R → +1, CENTER → 0).
local HARD_PAN = {
    PNO_1_L = -1,
    PNO_1_R = 1,
    PNO_2_L = -1,
    PNO_2_R = 1,
    PNO_MAIN_L = -1,
    PNO_MAIN_R = 1,
    HOUSE_L = -1,
    HOUSE_R = 1,
    CENTER = 0,
    AMB_L = -1,
    AMB_R = 1,
}

local function msg(text)
    reaper.ShowMessageBox(tostring(text), SCRIPT_TITLE, 0)
end

local function log(text)
    reaper.ShowConsoleMsg(tostring(text) .. "\n")
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
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

local function suggest_output_path(project_path)
    if project_path == "" then
        return ""
    end
    local dir = get_project_dir(project_path)
    local name = project_path:match("([^/\\]+)$") or "project.rpp"
    local base = name:gsub("%.RPP$", ""):gsub("%.rpp$", "")
    if dir ~= "" then
        return dir .. "/" .. base .. "_events.RPP"
    end
    return base .. "_events.RPP"
end

local function strip_extension(name)
    if not name or name == "" then
        return ""
    end
    local base = name:match("^(.*)%.([^%.]+)$")
    if base and base ~= "" then
        return base
    end
    return name
end

local function basename_from_path(path)
    if not path or path == "" then
        return ""
    end
    return path:match("([^/\\]+)$") or path
end

local function shell_quote(path)
    return '"' .. tostring(path):gsub('"', '\\"') .. '"'
end

--- Unix epoch seconds from macOS `stat`, or nil if unavailable.
local function stat_epoch(path, format)
    local cmd = STAT_BIN .. " -f " .. format .. " " .. shell_quote(path)
    local handle = io.popen(cmd)
    if not handle then
        return nil
    end
    local out = handle:read("*a")
    handle:close()
    local n = tonumber(trim(out or ""))
    if n and n > 0 then
        return n
    end
    return nil
end

--- Prefer birthtime (creation), fall back to mtime. Cached per path for the run.
local file_time_cache = {}
local function get_file_recorded_time(path)
    if not path or path == "" then
        return nil
    end
    local cached = file_time_cache[path]
    if cached ~= nil then
        if cached == false then
            return nil
        end
        return cached
    end
    local ts = stat_epoch(path, "%B") or stat_epoch(path, "%m")
    file_time_cache[path] = ts or false
    return ts
end

local function format_epoch(ts)
    if not ts then
        return "?"
    end
    return os.date("%Y-%m-%d %H:%M:%S", ts)
end

local function get_item_source_path(item)
    local take = reaper.GetActiveTake(item)
    if not take then
        return ""
    end
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then
        return ""
    end
    return reaper.GetMediaSourceFileName(src, "") or ""
end

local function normalize_spaces(s)
    return trim((s or ""):gsub("%s+", " "))
end

--- True when the source spelling is a named Pro Tools mic (not Audio N / leftover).
local function is_named_source(raw_name)
    local name = normalize_spaces(strip_extension(raw_name))
    if name == "" then
        return false
    end
    if name:match("^[Aa]udio%s+%d+") then
        return false
    end
    return true
end

--- Preference when multiple items target the same canonical track in one event.
--- Higher wins: named spelling > Audio-mapped; louder peak as tie-break; first wins ties.
local function conflict_preference_score(entry)
    local named = is_named_source(entry.label) and 1000 or 0
    local peak = entry.peak_db
    if type(peak) ~= "number" then
        peak = -999
    end
    return named + peak
end

--- Canonical logical track key from a take/track/source name.
local function logical_track_key(raw_name)
    local name = normalize_spaces(strip_extension(raw_name))
    if name == "" then
        return ""
    end

    -- Audio N_XX → mapped canonical or "Audio N"
    local audio_num = name:match("^[Aa]udio%s+(%d+)_%d+$")
    if not audio_num then
        audio_num = name:match("^[Aa]udio%s+(%d+)$")
    end
    if audio_num then
        local n = tonumber(audio_num)
        return AUDIO_NUM_TO_TRACK[n] or ("Audio " .. tostring(n))
    end

    -- choir house_NN L/R → HOUSE_L / HOUSE_R
    local choir_side = name:match("^[Cc]hoir%s+[Hh]ouse_%d+%s+([LR])$")
    if not choir_side then
        choir_side = name:match("^[Cc]hoir%s+[Hh]ouse%s+([LR])$")
    end
    if choir_side then
        return "HOUSE_" .. choir_side
    end

    -- haus amb_NN L/R → AMB_L / AMB_R
    local haus_side = name:match("^[Hh]aus%s+[Aa]mb_%d+%s+([LR])$")
    if not haus_side then
        haus_side = name:match("^[Hh]aus%s+[Aa]mb%s+([LR])$")
    end
    if haus_side then
        return "AMB_" .. haus_side
    end

    -- Strip trailing take index _NN (also handles "piano cemter OH _01").
    local base = name:gsub("%s*_%d+$", "")
    base = normalize_spaces(base)

    -- Preserve underscore vs space for sm81 pair distinction before lowercasing.
    local lower_raw = base:lower()
    local lower = normalize_spaces(lower_raw:gsub("_", " "))

    -- sm81 stereo pair: space form → PNO_1_L, underscore form → PNO_1_R (never merge).
    if lower_raw:match("^piano%s+r%s+sm81$") then
        return "PNO_1_L"
    end
    if lower_raw:match("^piano%s+r_sm81$") then
        return "PNO_1_R"
    end

    -- Okt vs oktav are distinct Octava capsules — never merge.
    if lower == "piano l okt" then
        return "PNO_2_L"
    end
    if lower == "piano l oktav" then
        return "PNO_2_R"
    end

    -- cemter vs center are distinct OH capsules — never merge.
    if lower == "piano cemter oh" then
        return "PNO_MAIN_L"
    end
    if lower == "piano center oh" then
        return "PNO_MAIN_R"
    end

    -- Generic choir house / haus amb with L/R token after underscore strip.
    local choir_lr = lower:match("^choir house ([lr])$")
    if choir_lr then
        return "HOUSE_" .. choir_lr:upper()
    end
    local amb_lr = lower:match("^haus amb ([lr])$")
    if amb_lr then
        return "AMB_" .. amb_lr:upper()
    end

    -- Leftover named sources (kon vox, laptop, rexa vox, etc.) keep their own track.
    return base
end

local function linear_peak_to_db(peak)
    if not peak or peak <= 0 then
        return -150.0
    end
    return 20.0 * math.log(peak, 10)
end

--- Max peak in dBFS via take peak cache (uses .reapeaks when available).
--- Returns nil if peaks cannot be read.
local function item_max_peak_db_from_take_peaks(item)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then
        return nil
    end
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if not length or length <= 0 then
        return nil
    end
    local src = reaper.GetMediaItemTake_Source(take)
    if not src then
        return nil
    end
    local nch = reaper.GetMediaSourceNumChannels(src)
    if not nch or nch < 1 then
        nch = 1
    end

    -- Bound buffer size for multi-GB files; still covers full item length.
    local max_samples = 10000
    local peakrate = 10.0
    local numsamples = math.floor(length * peakrate + 0.5)
    if numsamples < 1 then
        numsamples = 1
    elseif numsamples > max_samples then
        numsamples = max_samples
        peakrate = numsamples / length
    end

    local buf = reaper.new_array(numsamples * nch * 2)
    local rv = reaper.GetMediaItemTake_Peaks(take, peakrate, 0.0, nch, numsamples, 0, buf)
    local got = (rv or 0) % 0x100000 -- lower 20 bits = sample count
    if got < 1 then
        return nil
    end

    local max_abs = 0.0
    local count = got * nch -- first block = channel maximums
    for i = 1, count do
        local v = math.abs(buf[i] or 0)
        if v > max_abs then
            max_abs = v
        end
    end
    return linear_peak_to_db(max_abs)
end

--- Max peak in dBFS, or nil if unreadable. Prefer SWS NF_*, then CalculateNormalization, then take peaks.
local function item_max_peak_db(item)
    if reaper.NF_GetMediaItemMaxPeak then
        local peak = reaper.NF_GetMediaItemMaxPeak(item)
        if type(peak) == "number" and peak == peak then
            return peak
        end
    end
    if reaper.BR_GetMediaItemMaxPeak then
        local peak = reaper.BR_GetMediaItemMaxPeak(item)
        if type(peak) == "number" and peak == peak then
            return peak
        end
    end

    -- CalculateNormalization(source, normalizeTo, target, start, end):
    -- normalizeTo 2 = peak; returns gain to reach target. peak_db = target - gain.
    if reaper.CalculateNormalization then
        local take = reaper.GetActiveTake(item)
        if take and not reaper.TakeIsMIDI(take) then
            local src = reaper.GetMediaItemTake_Source(take)
            if src then
                local gain = reaper.CalculateNormalization(src, 2, 0.0, 0.0, 0.0)
                if type(gain) == "number" and gain == gain then
                    return -gain
                end
            end
        end
    end

    return item_max_peak_db_from_take_peaks(item)
end

local function silent_item_filename(entry)
    local base = basename_from_path(entry.source_path)
    if base ~= "" then
        return base
    end
    if entry.label and entry.label ~= "" then
        return entry.label
    end
    return "(unnamed)"
end

--- Analyze silence per media item. Marks entry.is_silent / entry.peak_db; does not
--- remove items or track keys. Unreadable peaks are kept (not treated as silent).
--- No-op when SKIP_SILENT is false (keeps full picture including silent files).
local function analyze_silence(items)
    if not SKIP_SILENT then
        log(string.format(
            "Silence skipping disabled (SKIP_SILENT=false); keeping all %d items including silent files.",
            #items
        ))
        for i = 1, #items do
            items[i].is_silent = false
        end
        return {}
    end

    log(string.format(
        "Silence scan: analyzing %d items (threshold %.0f dBFS; may build peak caches)...",
        #items,
        SILENCE_PEAK_DB
    ))

    local silent = {}
    local kept = 0
    local unread = 0
    for i = 1, #items do
        local entry = items[i]
        local peak_db = item_max_peak_db(entry.item)
        entry.peak_db = peak_db
        if type(peak_db) ~= "number" then
            -- Keep item: missing peaks must not drop a mic track for later events.
            entry.is_silent = false
            unread = unread + 1
            log(string.format(
                "PEAK n/a, keeping: %s",
                silent_item_filename(entry)
            ))
        elseif peak_db <= SILENCE_PEAK_DB then
            entry.is_silent = true
            silent[#silent + 1] = entry
            log(string.format(
                "SILENT skip: %s  peak=%.1f dBFS",
                silent_item_filename(entry),
                peak_db
            ))
        else
            entry.is_silent = false
            kept = kept + 1
        end
    end

    log(string.format(
        "Silence scan summary: skipped %d silent, kept %d, peak n/a kept %d (threshold %.0f dBFS)",
        #silent,
        kept,
        unread,
        SILENCE_PEAK_DB
    ))
    return silent
end

local function delete_entries(entries)
    local deleted = 0
    for i = 1, #(entries or {}) do
        local entry = entries[i]
        local track = reaper.GetMediaItem_Track(entry.item)
        if track then
            reaper.DeleteTrackMediaItem(track, entry.item)
            deleted = deleted + 1
        end
    end
    return deleted
end

local function pan_for_key(key)
    local hard = HARD_PAN[key]
    if hard ~= nil then
        return hard
    end
    if key:match("_L$") or key:match(" L$") then
        return -1
    end
    if key:match("_R$") or key:match(" R$") then
        return 1
    end
    return 0
end

local function canonical_order_index(key)
    for i = 1, #CANONICAL_TRACK_ORDER do
        if CANONICAL_TRACK_ORDER[i] == key then
            return i
        end
    end
    return nil
end

local function sort_logical_keys(keys)
    table.sort(keys, function(a, b)
        local a_ord = canonical_order_index(a)
        local b_ord = canonical_order_index(b)
        if a_ord and b_ord then
            return a_ord < b_ord
        end
        if a_ord and not b_ord then
            return true
        end
        if b_ord and not a_ord then
            return false
        end

        local a_audio = a:match("^Audio (%d+)$")
        local b_audio = b:match("^Audio (%d+)$")
        if a_audio and b_audio then
            return tonumber(a_audio) < tonumber(b_audio)
        end
        if a_audio and not b_audio then
            return true
        end
        if b_audio and not a_audio then
            return false
        end

        return a:lower() < b:lower()
    end)
    return keys
end

local function duration_key(length)
    return math.floor((length / DURATION_EPS) + 0.5) * DURATION_EPS
end

local function get_item_label(item)
    local take = reaper.GetActiveTake(item)
    if take then
        local take_name = reaper.GetTakeName(take)
        if take_name and take_name ~= "" then
            return take_name
        end
        local src = reaper.GetMediaItemTake_Source(take)
        if src then
            local src_path = reaper.GetMediaSourceFileName(src, "")
            local base = basename_from_path(src_path)
            if base ~= "" then
                return base
            end
        end
    end

    local track = reaper.GetMediaItem_Track(item)
    if track then
        local _, track_name = reaper.GetTrackName(track, "")
        if track_name and track_name ~= "" then
            return track_name
        end
    end
    return ""
end

local function collect_items(proj)
    local items = {}
    local item_count = reaper.CountMediaItems(proj)
    for i = 0, item_count - 1 do
        local item = reaper.GetMediaItem(proj, i)
        if item then
            local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
            local label = get_item_label(item)
            local key = logical_track_key(label)
            local source_path = get_item_source_path(item)
            items[#items + 1] = {
                item = item,
                length = length,
                dur_key = duration_key(length),
                label = label,
                logical_key = key,
                source_path = source_path,
                file_time = get_file_recorded_time(source_path),
                source_track = reaper.GetMediaItem_Track(item),
            }
        end
    end
    return items
end

--- Cluster by identical duration, then order clusters by earliest source-file time.
local function group_by_duration(items)
    local groups_by_key = {}
    local order = {}

    for i = 1, #items do
        local entry = items[i]
        local dk = entry.dur_key
        local group = groups_by_key[dk]
        if not group then
            group = {
                dur_key = dk,
                duration = entry.length, -- representative; refined below
                entries = {},
                file_time_min = nil,
                file_time_max = nil,
            }
            groups_by_key[dk] = group
            order[#order + 1] = dk
        end
        group.entries[#group.entries + 1] = entry
        -- Keep max length within cluster as region length so nothing is clipped.
        if entry.length > group.duration then
            group.duration = entry.length
        end
        local ft = entry.file_time
        if ft then
            if not group.file_time_min or ft < group.file_time_min then
                group.file_time_min = ft
            end
            if not group.file_time_max or ft > group.file_time_max then
                group.file_time_max = ft
            end
        end
    end

    local groups = {}
    for i = 1, #order do
        groups[#groups + 1] = groups_by_key[order[i]]
    end

    -- Earliest recorded event first; missing times last; duration as tie-breaker.
    table.sort(groups, function(a, b)
        local a_t = a.file_time_min or math.huge
        local b_t = b.file_time_min or math.huge
        if a_t ~= b_t then
            return a_t < b_t
        end
        return a.duration < b.duration
    end)
    return groups
end

--- Within one event, one item per destination track. Prefer named spelling, then louder peak.
local function resolve_track_collisions(group)
    local best_by_key = {}
    local kept = {}
    local dropped = {}

    for i = 1, #group.entries do
        local entry = group.entries[i]
        local key = entry.logical_key
        if key == "" then
            dropped[#dropped + 1] = entry
        else
            local score = conflict_preference_score(entry)
            local prev = best_by_key[key]
            if not prev then
                best_by_key[key] = { entry = entry, score = score, index = i }
            elseif score > prev.score then
                log(string.format(
                    "TRACK CONFLICT event duration=%.3fs key=%s: keeping '%s' (score=%.1f), dropping '%s' (score=%.1f)",
                    group.duration,
                    key,
                    entry.label,
                    score,
                    prev.entry.label,
                    prev.score
                ))
                dropped[#dropped + 1] = prev.entry
                best_by_key[key] = { entry = entry, score = score, index = i }
            else
                log(string.format(
                    "TRACK CONFLICT event duration=%.3fs key=%s: keeping '%s' (score=%.1f), dropping '%s' (score=%.1f)",
                    group.duration,
                    key,
                    prev.entry.label,
                    prev.score,
                    entry.label,
                    score
                ))
                dropped[#dropped + 1] = entry
            end
        end
    end

    -- Preserve first-seen order among winners.
    local winners = {}
    for key, info in pairs(best_by_key) do
        winners[#winners + 1] = info
    end
    table.sort(winners, function(a, b)
        return a.index < b.index
    end)
    for i = 1, #winners do
        kept[#kept + 1] = winners[i].entry
    end
    group.entries = kept
    group.dropped = dropped
end

--- Destination tracks = union of keys from ANY item in ANY event.
--- When SKIP_SILENT, silent takes are excluded here (they never remove a key that
--- appears with real audio elsewhere).
local function collect_logical_keys(groups)
    local seen = {}
    local keys = {}
    for g = 1, #groups do
        for i = 1, #groups[g].entries do
            local entry = groups[g].entries[i]
            local key = entry.logical_key
            local include = key ~= "" and not seen[key]
            if include and SKIP_SILENT and entry.is_silent then
                include = false
            end
            if include then
                seen[key] = true
                keys[#keys + 1] = key
            end
        end
    end
    return sort_logical_keys(keys)
end

local function prompt_output_path(default_path)
    if reaper.JS_Dialog_BrowseForSaveFile then
        local ok, path = reaper.JS_Dialog_BrowseForSaveFile(
            "Save rearranged project as",
            get_project_dir(default_path),
            default_path:match("([^/\\]+)$") or "project_events.RPP",
            "REAPER Project (*.RPP)\0*.RPP\0All Files (*.*)\0*.*\0"
        )
        if not ok or not path or path == "" then
            return nil
        end
        if not path:lower():match("%.rpp$") then
            path = path .. ".RPP"
        end
        return path
    end

    local ok, values = reaper.GetUserInputs(
        SCRIPT_TITLE,
        1,
        "Output .RPP path:extrawidth=300",
        default_path
    )
    if not ok then
        return nil
    end
    local path = trim(values)
    if path == "" then
        msg("Output path is required.")
        return nil
    end
    return path
end

local function clear_all_regions(proj)
    local _, num_markers, num_regions = reaper.CountProjectMarkers(proj)
    local total = num_markers + num_regions
    for i = total - 1, 0, -1 do
        local retval, is_region, _, _, _, idx = reaper.EnumProjectMarkers(i)
        if retval and is_region then
            reaper.DeleteProjectMarker(proj, idx, true)
        end
    end
end

local function create_destination_tracks(proj, keys)
    local track_by_key = {}
    local start_index = reaper.CountTracks(proj)

    for i = 1, #keys do
        local key = keys[i]
        local idx = start_index + i - 1
        reaper.InsertTrackAtIndex(idx, true)
        local track = reaper.GetTrack(proj, idx)
        reaper.GetSetMediaTrackInfo_String(track, "P_NAME", key, true)
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", pan_for_key(key))
        track_by_key[key] = track
    end

    return track_by_key
end

--- Remove empty source tracks only. Never delete destination mic tracks (they may
--- be empty in some regions when that mic was silent for those events).
local function delete_empty_tracks(proj, protect_tracks)
    local deleted = 0
    for i = reaper.CountTracks(proj) - 1, 0, -1 do
        local track = reaper.GetTrack(proj, i)
        if track and reaper.CountTrackMediaItems(track) == 0 then
            if protect_tracks and protect_tracks[track] then
                -- Keep canonical / leftover dest track for later non-silent events.
            else
                reaper.DeleteTrack(track)
                deleted = deleted + 1
            end
        end
    end
    return deleted
end

local function rearrange(proj, groups, track_by_key)
    clear_all_regions(proj)

    local cursor = 0.0
    local dropped_total = 0
    local event_index = 0
    local placed_groups = {}
    local silent_to_delete = {}

    for g = 1, #groups do
        local group = groups[g]

        if SKIP_SILENT then
            -- Per-item silence: exclude silent files from this event only; keep them
            -- off the rearrange timeline but do not drop destination track keys.
            local silent_here = {}
            local audible = {}
            for i = 1, #group.entries do
                local entry = group.entries[i]
                if entry.is_silent then
                    silent_here[#silent_here + 1] = entry
                    silent_to_delete[#silent_to_delete + 1] = entry
                else
                    audible[#audible + 1] = entry
                end
            end
            group.entries = audible
            group.silent_skipped = silent_here
        else
            group.silent_skipped = {}
        end

        resolve_track_collisions(group)
        dropped_total = dropped_total + #(group.dropped or {})

        -- Delete dropped conflict items so they do not remain on old tracks.
        delete_entries(group.dropped)

        -- Drop event/region only when no items remain to place.
        if #group.entries == 0 then
            group.skipped_empty = true
        else
            event_index = event_index + 1
            local region_start = cursor
            local region_end = region_start + group.duration

            for i = 1, #group.entries do
                local entry = group.entries[i]
                local dest = track_by_key[entry.logical_key]
                if dest then
                    reaper.MoveMediaItemToTrack(entry.item, dest)
                    reaper.SetMediaItemInfo_Value(entry.item, "D_POSITION", region_start)
                end
            end

            local region_name = string.format("%02d", event_index)
            reaper.AddProjectMarker2(proj, true, region_start, region_end, region_name, -1, 0)

            group.event_index = event_index
            placed_groups[#placed_groups + 1] = group
            cursor = region_end + REGION_GAP
        end
    end

    -- Remove silent items only after placement (item-level; dest tracks stay).
    if SKIP_SILENT then
        delete_entries(silent_to_delete)
    end

    return dropped_total, placed_groups
end

local function main()
    local proj = 0
    local project_path = get_project_path(proj)

    if project_path == "" then
        msg("Please save the project once before running this script (needed for default output path).")
        return
    end

    local item_count = reaper.CountMediaItems(proj)
    if item_count == 0 then
        msg("No media items found in the project.")
        return
    end

    local confirm = reaper.ShowMessageBox(
        "This will:\n" ..
            "1. Save a COPY of the project to a new path (original file stays untouched)\n" ..
            "2. Group items by duration into events, ordered chronologically by file recorded time\n" ..
            "3. Stack items on shared canonical mic tracks with L/R hard pan\n" ..
            "4. Leave a " .. tostring(REGION_GAP) .. "s (1 min) gap between regions\n\n" ..
            "Continue?",
        SCRIPT_TITLE,
        4
    )
    if confirm ~= 6 then
        return
    end

    local output_path = prompt_output_path(suggest_output_path(project_path))
    if not output_path then
        return
    end

    if output_path:lower() == project_path:lower() then
        local overwrite = reaper.ShowMessageBox(
            "Output path is the SAME as the current project file.\n\n" ..
                "This will overwrite the original on disk after rearrange.\n\nContinue anyway?",
            SCRIPT_TITLE,
            4
        )
        if overwrite ~= 6 then
            return
        end
    elseif file_exists(output_path) then
        local overwrite = reaper.ShowMessageBox(
            "Output file already exists. Overwrite it?\n\n" .. output_path,
            SCRIPT_TITLE,
            4
        )
        if overwrite ~= 6 then
            return
        end
    end

    if reaper.IsProjectDirty(proj) ~= 0 then
        local save_orig = reaper.ShowMessageBox(
            "Current project has unsaved changes.\n\n" ..
                "Save the ORIGINAL project file first?\n" ..
                "(Yes = save original, then Save As copy)\n" ..
                "(No = only write the copy; original file stays as last saved)",
            SCRIPT_TITLE,
            3 -- Yes/No/Cancel
        )
        if save_orig == 2 then -- Cancel
            return
        end
        if save_orig == 6 then -- Yes
            reaper.Main_SaveProject(proj, false)
        end
    end

    reaper.SetExtState(EXT_SECTION, "output_path", output_path, true)

    -- Save As copy first so rearrange happens on the copy's open document.
    reaper.Main_SaveProjectEx(proj, output_path, 0)
    project_path = get_project_path(proj)

    reaper.Undo_BeginBlock2(proj)
    reaper.PreventUIRefresh(1)

    local ok, err = xpcall(function()
        local items = collect_items(proj)
        -- Optional silence mark; when SKIP_SILENT=false this is a no-op (keep all).
        local silent_items = analyze_silence(items)

        local groups = group_by_duration(items)
        local keys = collect_logical_keys(groups)
        if #keys == 0 then
            error("No logical tracks could be derived from item names.")
        end

        local track_by_key = create_destination_tracks(proj, keys)
        local protect_tracks = {}
        for _, track in pairs(track_by_key) do
            protect_tracks[track] = true
        end

        local dropped_total, placed_groups = rearrange(proj, groups, track_by_key)
        local deleted_tracks = delete_empty_tracks(proj, protect_tracks)

        reaper.UpdateArrange()
        reaper.Main_SaveProjectEx(proj, output_path, 0)

        local report = {}
        report[#report + 1] = "=== " .. SCRIPT_TITLE .. " ==="
        report[#report + 1] = "Output: " .. output_path
        if SKIP_SILENT then
            report[#report + 1] = string.format("Silence threshold: %.0f dBFS", SILENCE_PEAK_DB)
            report[#report + 1] = string.format("Silent items skipped: %d", #silent_items)
        else
            report[#report + 1] = "Silence skipping: disabled (SKIP_SILENT=false); all items kept"
        end
        report[#report + 1] = string.format("Events: %d", #placed_groups)
        report[#report + 1] = string.format("Logical tracks: %d", #keys)
        report[#report + 1] = string.format("Empty source tracks deleted: %d", deleted_tracks)
        report[#report + 1] = string.format("Same-event track conflicts removed: %d", dropped_total)
        report[#report + 1] = string.format("Region gap: %.0fs", REGION_GAP)
        report[#report + 1] = ""
        report[#report + 1] = "Canonical mic map (Audio N / named → track):"
        report[#report + 1] = "  Audio 1→PNO_1_R  Audio 2→PNO_1_L  Audio 3→PNO_2_L  Audio 4→PNO_2_R"
        report[#report + 1] = "  Audio 5→PNO_MAIN_L  Audio 6→PNO_MAIN_R  Audio 7→HOUSE_L  Audio 8→HOUSE_R"
        report[#report + 1] = "  Audio 13→CENTER  Audio 27→AMB_L  Audio 28→AMB_R"
        report[#report + 1] = "  piano R sm81→PNO_1_L  piano R_sm81→PNO_1_R"
        report[#report + 1] = "  piano L Okt→PNO_2_L  piano L oktav→PNO_2_R"
        report[#report + 1] = "  piano cemter OH→PNO_MAIN_L  piano center OH→PNO_MAIN_R"
        report[#report + 1] = "  choir house L/R→HOUSE_*  haus amb L/R→AMB_*"
        report[#report + 1] = ""
        report[#report + 1] = "Events (chronological by source-file time):"
        for g = 1, #placed_groups do
            local group = placed_groups[g]
            report[#report + 1] = string.format(
                "  %02d  start=%s  max=%s  duration=%.3fs  items=%d",
                group.event_index or g,
                format_epoch(group.file_time_min),
                format_epoch(group.file_time_max),
                group.duration,
                #group.entries
            )
        end
        report[#report + 1] = ""
        report[#report + 1] = "Tracks:"
        for i = 1, #keys do
            local key = keys[i]
            local pan = pan_for_key(key)
            local pan_label = "C"
            if pan < 0 then
                pan_label = "L"
            elseif pan > 0 then
                pan_label = "R"
            end
            report[#report + 1] = string.format("  %s  pan=%s", key, pan_label)
        end

        log(table.concat(report, "\n"))
        local done_stats
        if SKIP_SILENT then
            done_stats = string.format(
                "Events: %d | Tracks: %d | Silent skipped: %d | Conflicts removed: %d",
                #placed_groups,
                #keys,
                #silent_items,
                dropped_total
            )
        else
            done_stats = string.format(
                "Events: %d | Tracks: %d | Silence skip: off | Conflicts removed: %d",
                #placed_groups,
                #keys,
                dropped_total
            )
        end
        msg(table.concat({
            "Done.",
            "",
            "Saved copy: " .. output_path,
            done_stats,
            "",
            "See the REAPER console for the full summary.",
        }, "\n"))
    end, debug.traceback)

    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock2(proj, SCRIPT_TITLE, -1)

    if not ok then
        msg("Rearrange failed:\n\n" .. tostring(err))
        log("ERROR: " .. tostring(err))
    end
end

main()
