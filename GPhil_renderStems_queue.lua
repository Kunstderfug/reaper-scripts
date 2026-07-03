-- GPhil_renderStems_queue.lua
-- Queue tempo-variant renders using GPHIL_STEMS preset and current track selection.
--
-- Features:
--   - You manually select the tracks to render (no stem group parsing).
--   - Configure tempo range: base, start, step, end, tempo multiplier.
--   - Optional click render at base tempo using GPHIL_CLICK preset.
--   - For each tempo:
--       * Scales the project tempo map proportionally.
--       * Keeps your current track selection logic (preset handles stems).
--       * Applies GPHIL_STEMS preset.
--       * Sets render pattern:
--           AUDIO/$region/STEMS/$project_$region_<tempo>_$folders
--       * Adds a job to the Render Queue.
--   - Restores:
--       * Original tempo map.
--       * Original render pattern.
--       * Original track selection.
--
-- Assumptions:
--   - "Apply render preset - GPHIL_CLICK" exists (via cfillion's tool) if click renders are enabled.
--   - "Apply render preset - GPHIL_STEMS" exists (via cfillion's tool).
--   - GPHIL_STEMS preset renders from selected tracks.
--   - Render queue delay is disabled or acceptable.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local ADD_TO_QUEUE_CMD = 41823 -- File: Add project to render queue, using most recent render settings
local CMD_APPLY_GPHIL_CLICK = "_RSe07780b8d7eb28a48e88b3b7e3467d7c79cade66"
local CMD_APPLY_GPHIL_STEMS = "_RSa8c57e22cbf0ac88d95a5178ce4ede7f039e74a2"

local CLICK_PATTERN_BASE = "CLICKDATA/$project_$region_120"

-- Base pattern; the trailing tempo placeholder before the final wildcard will be replaced.
-- Example:
--   AUDIO/$region/STEMS/$project_$region_155_$trackname
-- Produces:
--   AUDIO/$region/STEMS/$project_$region_<tempo>_$trackname
local STEMS_PATTERN_BASE = "AUDIO/$region/STEMS/$project_$region_155_$trackname"

local EXT_SECTION = "GPHIL_STEMS_RENDER"

local function log(msg)
    reaper.ShowConsoleMsg(tostring(msg) .. "\n")
end

local function find_click_track(proj)
    local track_count = reaper.CountTracks(proj)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(proj, i)
        local _, name = reaper.GetTrackName(track, "")
        if name and name:lower():find("clicktrack") then
            return track
        end
    end
    return nil
end

local function parse_bool(str, default_if_empty)
    if not str or str == "" then
        return default_if_empty
    end
    local s = str:lower()
    return (s == "y" or s == "yes" or s == "1" or s == "true")
end

local function bool_to_yn(value)
    return value and "Y" or "N"
end

local function apply_preset(cmd_id, label)
    if not cmd_id or cmd_id == 0 then
        reaper.ShowMessageBox(
            "Preset action for " .. label .. " is not configured.",
            "Error",
            0
        )
        return false
    end

    local command
    if type(cmd_id) == "string" then
        command = reaper.NamedCommandLookup(cmd_id)
    else
        command = cmd_id
    end

    if not command or command == 0 then
        reaper.ShowMessageBox(
            "Could not resolve command for " .. label .. " (" .. tostring(cmd_id) .. ").",
            "Error",
            0
        )
        return false
    end

    reaper.Main_OnCommand(command, 0)
    return true
end

local function get_track_by_name_contains(proj, name_fragment)
    local lc = name_fragment:lower()
    local track_count = reaper.CountTracks(proj)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(proj, i)
        local _, name = reaper.GetTrackName(track, "")
        if name and name:lower():find(lc, 1, true) then
            return track
        end
    end
    return nil
end

local function get_render_pattern(proj)
    local ok, val = reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", "", false)
    if not ok then
        return ""
    end
    return val
end

local function set_render_pattern(proj, pattern)
    reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", pattern or "", true)
end

local function load_last(proj)
    local function get_num(key, fallback)
        local retval, val = reaper.GetProjExtState(proj, EXT_SECTION, key)
        if retval == 1 then
            local n = tonumber(val)
            if n then
                return n
            end
        end
        return fallback
    end

    local function get_bool(key, fallback)
        local retval, val = reaper.GetProjExtState(proj, EXT_SECTION, key)
        if retval == 1 then
            return parse_bool(val, fallback)
        end
        return fallback
    end

    local base = get_num("base_tempo", 60)
    local start = get_num("start_tempo", base)
    local step = get_num("step", 5)
    local end_tempo = get_num("end_tempo", start + step * 2)
    local multiplier = get_num("tempo_multiplier", 1)
    local render_click = get_bool("render_click", true)

    return base, start, step, end_tempo, multiplier, render_click
end


local function save_last(proj, base, start_t, step, end_t, multiplier, render_click)
    reaper.SetProjExtState(proj, EXT_SECTION, "base_tempo", tostring(base))
    reaper.SetProjExtState(proj, EXT_SECTION, "start_tempo", tostring(start_t))
    reaper.SetProjExtState(proj, EXT_SECTION, "step", tostring(step))
    reaper.SetProjExtState(proj, EXT_SECTION, "end_tempo", tostring(end_t))
    reaper.SetProjExtState(proj, EXT_SECTION, "tempo_multiplier", tostring(multiplier))
    reaper.SetProjExtState(proj, EXT_SECTION, "render_click", render_click and "Y" or "N")
end

local function capture_tempo_map(proj)
    local list = {}
    local cnt = reaper.CountTempoTimeSigMarkers(proj)
    for i = 0, cnt - 1 do
        local retval, timepos, measurepos, beatpos, bpm, num, denom, linear =
            reaper.GetTempoTimeSigMarker(proj, i)
        if retval then
            list[#list + 1] = {
                timepos = timepos,
                measurepos = measurepos,
                beatpos = beatpos,
                bpm = bpm,
                timesig_num = num,
                timesig_denom = denom,
                lineartempo = linear
            }
        end
    end
    return list
end

local function restore_tempo_map(proj, markers)
    local cnt = reaper.CountTempoTimeSigMarkers(proj)
    for i = cnt - 1, 0, -1 do
        reaper.DeleteTempoTimeSigMarker(proj, i)
    end
    for i = 1, #markers do
        local m = markers[i]
        reaper.SetTempoTimeSigMarker(
            proj, -1,
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

local function scale_tempo_map(proj, markers_original, factor)
    if not factor or factor == 0 then
        return
    end

    -- To mimic "Adjust entire tempo envelope" we not only scale BPM,
    -- but also move tempo markers in time by the inverse factor so that
    -- musical (beat) positions are preserved and the project stretches.
    local time_scale = 1.0 / factor

    local cnt = reaper.CountTempoTimeSigMarkers(proj)
    for i = cnt - 1, 0, -1 do
        reaper.DeleteTempoTimeSigMarker(proj, i)
    end

    for i = 1, #markers_original do
        local m = markers_original[i]
        local new_bpm = m.bpm * factor
        local new_timepos = m.timepos * time_scale
        reaper.SetTempoTimeSigMarker(
            proj, -1,
            new_timepos,
            m.measurepos,
            m.beatpos,
            new_bpm,
            m.timesig_num,
            m.timesig_denom,
            m.lineartempo
        )
    end
end

local function with_tempo_suffix(pattern, tempo_str)
    local prefix, existing = pattern:match("^(.*)_(%d+)%s*$")
    if prefix and existing then
        return prefix .. "_" .. tempo_str
    end
    return pattern .. "_" .. tempo_str
end

local function stems_pattern_for_tempo(tempo)
    local tempo_str = tostring(math.floor(tempo + 0.5))

    -- If STEMS_PATTERN_BASE matches ..._(%d+)_$wildcard, replace that number.
    local prefix, existing, wildcard = STEMS_PATTERN_BASE:match("^(.*)_(%d+)_($[%w_]+)$")
    if prefix and existing and wildcard then
        return prefix .. "_" .. tempo_str .. "_" .. wildcard
    end

    -- If pattern ends with _$wildcard but without a tempo marker, insert tempo before it.
    local wildcard_prefix, trailing_wildcard = STEMS_PATTERN_BASE:match("^(.*)_($[%w_]+)$")
    if wildcard_prefix and trailing_wildcard then
        return wildcard_prefix .. "_" .. tempo_str .. "_" .. trailing_wildcard
    end

    -- Fallback: append tempo.
    return STEMS_PATTERN_BASE .. "_" .. tempo_str
end

local STEM_TRACK_NAMES = {
    "STEMS",
    "W_STEM",
    "B_STEM",
    "P_STEM",
    "S_STEM"
}

local function capture_and_unmute_stem_tracks(proj)
    local state = {}
    for i = 1, #STEM_TRACK_NAMES do
        local name = STEM_TRACK_NAMES[i]
        local track = get_track_by_name_contains(proj, name)
        if track then
            local muted = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")
            state[#state + 1] = {
                track = track,
                muted = muted
            }
            if muted == 1 then
                reaper.SetMediaTrackInfo_Value(track, "B_MUTE", 0)
            end
        end
    end
    return state
end

local function restore_stem_tracks_mute_state(stem_state)
    if not stem_state then
        return
    end
    for i = 1, #stem_state do
        local entry = stem_state[i]
        if entry.track and reaper.ValidatePtr2(0, entry.track, "MediaTrack*") then
            reaper.SetMediaTrackInfo_Value(entry.track, "B_MUTE", entry.muted or 0)
        end
    end
end

local function main()
    local proj = 0

    if not ADD_TO_QUEUE_CMD or ADD_TO_QUEUE_CMD <= 0 then
        reaper.ShowMessageBox(
            "ADD_TO_QUEUE_CMD invalid. Check 'File: Add project to render queue, using most recent render settings'.",
            "Error",
            0
        )
        return
    end

    local last_base, last_start, last_step, last_end, last_multiplier, last_render_click = load_last(proj)

    local title = "GPHIL - Queue STEMS (tempo variants)"
    local num_inputs = 6
    local captions =
        "Original base tempo," ..
        "Start tempo," ..
        "Step," ..
        "End tempo," ..
        "Tempo multiplier," ..
        "Render Click Files (Y/N)"
    local defaults = string.format(
        "%g,%g,%g,%g,%g,%s",
        last_base,
        last_start,
        last_step,
        last_end,
        last_multiplier,
        bool_to_yn(last_render_click)
    )

    local ok, input_str = reaper.GetUserInputs(title, num_inputs, captions, defaults)
    if not ok then
        return
    end

    local function split6(str)
        local a, rest = str:match("^(.-),(.*)$")
        if not a then return end
        local b
        b, rest = rest:match("^(.-),(.*)$")
        if not b then return end
        local c
        c, rest = rest:match("^(.-),(.*)$")
        if not c then return end
        local d
        d, rest = rest:match("^(.-),(.*)$")
        if not d then return end
        local e, f = rest:match("^(.-),(.*)$")
        if not e or not f then return end
        return a, b, c, d, e, f
    end

    local base_str, start_str, step_str, end_str, multiplier_str, render_click_str = split6(input_str)
    if not base_str then
        reaper.ShowMessageBox(
            "Invalid input format.\nExpected 6 fields: Base, Start, Step, End, Tempo multiplier, Render Click Files.",
            "Error",
            0
        )
        return
    end

    local base_tempo = tonumber((base_str or ""):match("^%s*(.-)%s*$"))
    local start_tempo = tonumber((start_str or ""):match("^%s*(.-)%s*$"))
    local step = tonumber((step_str or ""):match("^%s*(.-)%s*$"))
    local end_tempo = tonumber((end_str or ""):match("^%s*(.-)%s*$"))
    local tempo_multiplier = tonumber((multiplier_str or ""):match("^%s*(.-)%s*$"))
    local render_click = parse_bool((render_click_str or ""):match("^%s*(.-)%s*$"), last_render_click)

    if not (base_tempo and start_tempo and step and end_tempo and tempo_multiplier) or step == 0 then
        reaper.ShowMessageBox("All tempo values must be numbers and step non-zero.", "Error", 0)
        return
    end
    if base_tempo <= 0 or tempo_multiplier <= 0 then
        reaper.ShowMessageBox("Base tempo and multiplier must be greater than zero.", "Error", 0)
        return
    end
    if (end_tempo - start_tempo) * step < 0 then
        reaper.ShowMessageBox("Step direction does not move from start to end.", "Error", 0)
        return
    end

    save_last(proj, base_tempo, start_tempo, step, end_tempo, tempo_multiplier, render_click)

    local base_tempo_actual = base_tempo * tempo_multiplier
    local start_tempo_actual = start_tempo * tempo_multiplier
    local end_tempo_actual = end_tempo * tempo_multiplier

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)

    local markers_original = capture_tempo_map(proj)
    local original_pattern = get_render_pattern(proj)
    local click_track = find_click_track(proj)
    local original_click_mute = nil
    if click_track then
        original_click_mute = reaper.GetMediaTrackInfo_Value(click_track, "B_MUTE")
    end

    -- Save original selection
    local prev_sel = {}
    local track_count = reaper.CountTracks(proj)
    for i = 0, track_count - 1 do
        local tr = reaper.GetTrack(proj, i)
        if reaper.IsTrackSelected(tr) then
            prev_sel[#prev_sel + 1] = tr
        end
    end

    -- Ensure key STEM tracks are unmuted during rendering (and remember original state).
    local stems_mute_state = capture_and_unmute_stem_tracks(proj)

    reaper.ShowConsoleMsg("")
    log("=== GPHIL STEMS - queue (tempo variants) ===")
    log("Stems selection: (manual - current track selection)")
    log(string.format("Original base tempo: %g (REAPER: %g)", base_tempo, base_tempo_actual))
    log(string.format("Tempo multiplier: %g", tempo_multiplier))
    log(string.format("Tempo range (display): %g to %g step %g", start_tempo, end_tempo, step))
    log(string.format(
        "Tempo range (REAPER quarter-note BPM): %g to %g step %g",
        start_tempo_actual,
        end_tempo_actual,
        step * tempo_multiplier
    ))
    log("Render click files: " .. (render_click and "YES" or "NO"))
    log("Click pattern base: " .. CLICK_PATTERN_BASE)
    log("Using GPHIL_STEMS preset: " .. tostring(CMD_APPLY_GPHIL_STEMS))
    log("Base stems pattern: " .. STEMS_PATTERN_BASE)
    if click_track then
        local _, name = reaper.GetTrackName(click_track, "")
        log("CLICKTRACK found: " .. (name or "<unnamed>"))
    else
        log("CLICKTRACK not found (name contains 'CLICKTRACK').")
    end
    log("-------------------------------------------")

    if render_click then
        if not click_track then
            log("SKIP CLICK: no CLICKTRACK found.")
        else
            restore_tempo_map(proj, markers_original)

            reaper.Main_OnCommand(40297, 0)
            reaper.SetTrackSelected(click_track, true)

            if original_click_mute ~= nil then
                reaper.SetMediaTrackInfo_Value(click_track, "B_MUTE", 0)
            end

            if apply_preset(CMD_APPLY_GPHIL_CLICK, "GPHIL_CLICK") then
                local base_suffix = math.floor(base_tempo + 0.5)
                local click_pattern = with_tempo_suffix(CLICK_PATTERN_BASE, tostring(base_suffix))
                set_render_pattern(proj, click_pattern)

                reaper.Main_OnCommand(ADD_TO_QUEUE_CMD, 0)
                log(string.format(
                    "CLICK QUEUED: tempo=%g (REAPER: %g), pattern=%s",
                    base_tempo,
                    base_tempo_actual,
                    click_pattern
                ))
            else
                log("SKIP CLICK: failed to apply GPHIL_CLICK preset.")
            end

            if original_click_mute ~= nil then
                reaper.SetMediaTrackInfo_Value(click_track, "B_MUTE", original_click_mute)
            end

            reaper.Main_OnCommand(40297, 0)
            for i = 1, #prev_sel do
                reaper.SetTrackSelected(prev_sel[i], true)
            end

            restore_tempo_map(proj, markers_original)
            set_render_pattern(proj, original_pattern)
        end
    end

    local tempo = start_tempo
    local iteration = 1

    while (step > 0 and tempo <= end_tempo) or (step < 0 and tempo >= end_tempo) do
        local target_tempo = tempo
        local target_tempo_actual = target_tempo * tempo_multiplier
        local factor = target_tempo_actual / base_tempo_actual

        -- Scale tempo map for this tempo
        scale_tempo_map(proj, markers_original, factor)

        if click_track and original_click_mute ~= nil then
            reaper.SetMediaTrackInfo_Value(click_track, "B_MUTE", 1)
        end

        if not apply_preset(CMD_APPLY_GPHIL_STEMS, "GPHIL_STEMS") then
            log("Failed to apply GPHIL_STEMS preset. Stopping.")
            break
        end

        local pattern = stems_pattern_for_tempo(target_tempo)
        set_render_pattern(proj, pattern)

        reaper.Main_OnCommand(ADD_TO_QUEUE_CMD, 0)

        log(string.format(
            "#%d QUEUED: tempo=%g (REAPER: %g, factor=%.6f), pattern=%s",
            iteration,
            target_tempo,
            target_tempo_actual,
            factor,
            pattern
        ))

        iteration = iteration + 1
        tempo = tempo + step
    end

    -- Restore tempo, pattern, and original track selection
    restore_tempo_map(proj, markers_original)
    set_render_pattern(proj, original_pattern)
    restore_stem_tracks_mute_state(stems_mute_state)
    if click_track and original_click_mute ~= nil then
        reaper.SetMediaTrackInfo_Value(click_track, "B_MUTE", original_click_mute)
    end

    reaper.Main_OnCommand(40297, 0)
    for i = 1, #prev_sel do
        reaper.SetTrackSelected(prev_sel[i], true)
    end

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("GPHIL STEMS - queue (tempo variants)", -1)

    log("-------------------------------------------")
    log("Done. STEMS tempo variants added to queue. Original state restored.")
end

main()
