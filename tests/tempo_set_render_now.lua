-- Run from the repo root: lua tests/tempo_set_render_now.lua
-- Exercise the actual confirmed-grid main path against a stateful fake REAPER project.
local path = "GPhil_tempoSet_render_gfx_direct.lua"
local source_file = assert(io.open(path))
local source = source_file:read("*a")
source_file:close()
local section = assert(source:match('local EXT_SECTION%s*=%s*"([^"]+)"'))
local regular_preset = "_RS67c8ada3573313a7c135385939c19cbc2450964d"
local click_preset = "_RSe07780b8d7eb28a48e88b3b7e3467d7c79cade66"

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = clone(entry) end
    return result
end

local function equal(actual, expected, label)
    if type(expected) == "table" then
        assert(type(actual) == "table", label .. ": expected table")
        for key, value in pairs(expected) do equal(actual[key], value, label .. "." .. key) end
        for key in pairs(actual) do assert(expected[key] ~= nil, label .. ": unexpected key " .. tostring(key)) end
    elseif type(expected) == "number" then
        assert(type(actual) == "number" and math.abs(actual - expected) < 1e-8,
            string.format("%s: expected %s, got %s", label, expected, tostring(actual)))
    else
        assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

local function run_case(options)
    local project = {}
    local other_project = {}
    local active_project = project
    local points = {
        { time = 0, bpm = 120, num = 5, denom = 4, flags = 3, linear = false, basis = 1, pattern = "" },
        { time = 4, bpm = 126, num = 0, denom = 0, flags = 0, linear = true, basis = 1, pattern = "" },
        { time = 8, bpm = 132, num = 4, denom = 4, flags = 29, linear = false, basis = 1.5, pattern = "ABBB" },
        { time = 12, bpm = 132, num = 6, denom = 4, flags = 7, linear = false, basis = 1, pattern = "" }
    }
    local region_start = options.region_start or 0
    for _, point in ipairs(points) do point.time = point.time + region_start end
    local original_points = clone(points)
    local project_bpm, project_bpi = 120, 5
    local tracks = {
        { name = "Strings", B_MUTE = 0, I_SOLO = 0, selected = true },
        { name = "CLICKTRACK", B_MUTE = 1, I_SOLO = 0, selected = false },
        { name = "SOLO", B_MUTE = 0, I_SOLO = 0, selected = true }
    }
    local original_tracks = clone(tracks)
    local regions = {
        { B_ISREGION = 1, B_UISEL = 1, D_STARTPOS = 0, D_ENDPOS = 16, I_NUMBER = 1, name = "Section" },
        { B_ISREGION = 1, B_UISEL = 0, D_STARTPOS = 16, D_ENDPOS = 24, I_NUMBER = 2, name = "Other" }
    }
    for _, region in ipairs(regions) do
        region.D_STARTPOS = region.D_STARTPOS + region_start
        region.D_ENDPOS = region.D_ENDPOS + region_start
    end
    local original_regions = clone(regions)
    local pending = table.concat({ 0, region_start, region_start + 16, "Section", 1, 120, 100, 10, 120, options.click and 1 or 0, 1 }, "\t")
    local ext = {
        pending_region_rows_v1 = pending,
        pending_queue_options_v1 = options.legacy_queue and "skip_existing=0" or "skip_existing=0\nmode=render_now",
        render_click = "N"
    }
    if options.grid then
        ext.pending_region_rows_v1, ext.pending_queue_options_v1 = nil, nil
    end
    local dispatched_options, deferred = nil, {}
    local numeric, strings = {}, {}
    for key in source:gmatch('"(RENDER_[A-Z0-9_]+)"') do numeric[key] = #key + 0.125 end
    for _, key in ipairs({ "RENDER_FILE", "RENDER_PATTERN", "RENDER_EXTRAFILEDIR", "RENDER_FORMAT", "RENDER_FORMAT2" }) do
        numeric[key], strings[key] = nil, "original-" .. key
    end
    local original_numeric, original_strings = clone(numeric), clone(strings)
    local passes, messages, logs, exit_callbacks = {}, {}, {}, {}
    local outputs = {}
    if options.preexisting then
        for tempo = 100, 120, 10 do
            outputs["/fake-output/AUDIO/Section/Suite_Section_" .. tempo .. ".wav"] = "previous rendered audio"
        end
    end
    local queue_calls, render_calls, undo_begin, undo_end = 0, 0, 0, 0
    local render_stats = ""
    local function marker_at(time)
        for _, point in ipairs(points) do if math.abs(point.time - time) < 1e-7 then return point end end
    end
    local function effective_bpm(time)
        local result = project_bpm
        for _, point in ipairs(points) do
            if point.time > time then break end
            if point.flags & 2 == 0 then result = point.bpm end
        end
        return result
    end
    local api
    local function target_path()
        return strings.RENDER_FILE .. "/" .. strings.RENDER_PATTERN:gsub("%$project", "Suite"):gsub("%$region", "Section") .. ".wav"
    end
    local function render_pass(command)
        if command == 41823 then queue_calls = queue_calls + 1 else render_calls = render_calls + 1 end
        equal(numeric.RENDER_BOUNDSFLAG, 5, "selected-region bounds")
        assert(regions[1].B_UISEL == 1 and regions[2].B_UISEL == 0, "only requested section is selected")
        local pass = { pattern = strings.RENDER_PATTERN, bpm = effective_bpm(regions[1].D_STARTPOS),
            region_start = regions[1].D_STARTPOS, points = clone(points), tracks = clone(tracks) }
        passes[#passes + 1] = pass
        if command == 42230 then
            if options.render_error then error("injected render failure") end
            if options.terminate then
                for _, callback in ipairs(exit_callbacks) do callback() end
                error("terminated during render")
            end
            outputs[target_path()] = "rendered audio " .. render_calls
            if options.cancel and render_calls == 2 then
                render_stats = "" -- Cancel with partial audio kept must still stop the sequence.
            else
                render_stats = "FILE:" .. target_path() .. ";PEAK:-1.0;RMS:-5.0;CLIP:0;"
                if options.tab_switch then active_project = other_project end
            end
        end
    end
    api = {
        EnumProjects = function() return active_project, "/fake-project/Suite.rpp" end,
        SelectProjectInstance = function(requested_project) active_project = requested_project end,
        ValidatePtr = function() return true end,
        get_action_context = function() return false, path, 0, 0, 0, 0, 0 end,
        GetAppVersion = function() return options.unsupported and "6.67" or "7.50" end,
        GetAllProjectPlayStates = function() return 0 end,
        CountTracks = function() return #tracks end,
        GetTrack = function(_, index) return tracks[index + 1] end,
        GetTrackName = function(track) return true, track.name end,
        GetMediaTrackInfo_Value = function(track, key) return assert(track[key], key) end,
        SetMediaTrackInfo_Value = function(track, key, value) track[key] = value; return true end,
        IsTrackSelected = function(track) return track.selected end,
        SetTrackSelected = function(track, selected) track.selected = selected end,
        SetOnlyTrackSelected = function(track)
            for _, candidate in ipairs(tracks) do candidate.selected = candidate == track end
        end,
        ValidatePtr2 = function() return true end,
        GetNumRegionsOrMarkers = function() return #regions end,
        EnumProjectMarkers3 = function(_, index)
            local region = regions[index + 1]
            if not region then return 0 end
            return 1, true, region.D_STARTPOS, region.D_ENDPOS, region.name, region.I_NUMBER, 0
        end,
        GetRegionOrMarker = function(_, index) return regions[index + 1] end,
        GetRegionOrMarkerInfo_Value = function(_, region, key) return assert(region[key], key) end,
        SetRegionOrMarkerInfo_Value = function(_, region, key, value) region[key] = value; return true end,
        GetSetRegionOrMarkerInfo_String = function(_, region) return true, region.name end,
        GetProjExtState = function(_, requested_section, key)
            equal(requested_section, section, "project state section")
            return ext[key] and 1 or 0, ext[key] or ""
        end,
        SetProjExtState = function(_, _, key, value)
            ext[key] = value
            if key == "pending_queue_options_v1" and value ~= "" then dispatched_options = value end
            return 1
        end,
        CountTempoTimeSigMarkers = function() return #points end,
        GetTempoTimeSigMarker = function(_, index)
            local point = points[index + 1]
            if not point then return false end
            return true, point.time, -1, -1, point.bpm, point.num, point.denom, point.linear
        end,
        DeleteTempoTimeSigMarker = function(_, index) table.remove(points, index + 1); return true end,
        SetTempoTimeSigMarker = function(_, index, time, measure, beat, bpm, num, denom, linear)
            assert(measure == -1 and beat == -1, "time-based marker writes must disable measure coordinates")
            local point = { time = time, bpm = bpm, num = num, denom = denom, linear = linear,
                flags = num > 0 and 1 or 0, basis = 1, pattern = "" }
            if index == -1 then points[#points + 1] = point else points[index + 1] = point end
            table.sort(points, function(a, b) return a.time < b.time end)
            return true
        end,
        GetSetTempoTimeSigMarkerFlag = function(_, index, flags, set)
            local point = assert(points[index + 1])
            if set then point.flags = flags end
            return point.flags
        end,
        GetSetTempoTimeSigMarkerBasis = function(_, index, basis, set)
            local point = assert(points[index + 1])
            if set then point.basis = basis end
            return point.basis
        end,
        TimeMap_GetMetronomePattern = function(_, time, pattern)
            local point = assert(marker_at(time), "metronome marker exists")
            if pattern:sub(1, 4) == "SET:" then point.pattern = pattern:sub(5) end
            return 1, point.pattern
        end,
        GetProjectTimeSignature2 = function(requested_project)
            assert(requested_project == project and active_project == project, "default getter uses original active project")
            return project_bpm, project_bpi
        end,
        SetCurrentBPM = function(requested_project, bpm)
            assert(requested_project == project and active_project == project, "default BPM setter uses original active project")
            -- This fake project uses beat-based regions, following inverse tempo scale.
            local time_scale = options.seconds_timebase and 1 or project_bpm / bpm
            for _, region in ipairs(regions) do
                region.D_STARTPOS = region.D_STARTPOS * time_scale
                region.D_ENDPOS = region.D_ENDPOS * time_scale
            end
            project_bpm = bpm
        end,
        TimeMap2_GetDividedBpmAtTime = function(_, time) return effective_bpm(time) end,
        TimeMap2_timeToQN = function(_, time) return time * 2 end,
        TimeMap2_QNToTime = function(_, qn) return qn / 2 end,
        UpdateTimeline = function() end,
        GetSetProjectInfo = function(_, key, value, set)
            if set then numeric[key] = value end
            return assert(numeric[key], key)
        end,
        GetSetProjectInfo_String = function(_, key, value, set)
            if key == "RENDER_TARGETS" then return true, target_path() end
            if key == "RENDER_STATS" then
                if value == "42230" then render_pass(42230) end
                return true, render_stats
            end
            if set then strings[key] = value end
            return true, assert(strings[key], key)
        end,
        GetProjectPathEx = function() return "/fake-project" end,
        GetProjectName = function() return "Suite.rpp" end,
        NamedCommandLookup = function(command)
            if command == regular_preset then return 9876 end
            if command == click_preset then return 9877 end
            error("unexpected preset: " .. tostring(command))
        end,
        Main_OnCommand = function(command)
            assert(active_project == project, "preset/selection/render commands must not affect another tab")
            if command == 40297 then
                for _, track in ipairs(tracks) do track.selected = false end
            elseif command == 9876 or command == 9877 then
                for key in pairs(numeric) do numeric[key] = 123 end
                for key in pairs(strings) do strings[key] = "preset-" .. key end
                strings.RENDER_FILE = "/fake-output"
                strings.RENDER_FORMAT2 = ""
            elseif command == 41823 or command == 42230 then
                render_pass(command)
            else
                error("unexpected command: " .. tostring(command))
            end
        end,
        Undo_BeginBlock2 = function(requested_project)
            assert(requested_project == project, "Undo begin targets original project")
            undo_begin = undo_begin + 1
        end,
        Undo_EndBlock2 = function(requested_project)
            assert(requested_project == project, "Undo end targets original project")
            undo_end = undo_end + 1
        end,
        atexit = function(callback) exit_callbacks[#exit_callbacks + 1] = callback end,
        UpdateArrange = function() end,
        ShowConsoleMsg = function(message) logs[#logs + 1] = message end,
        ShowMessageBox = function(message) messages[#messages + 1] = message; return 1 end,
        defer = function(callback)
            assert(options.grid, "confirmed rows should not open the grid")
            deferred[#deferred + 1] = callback
        end,
        file_exists = function(candidate) return outputs[candidate] ~= nil end,
        time_precise = function() return os.clock() end
    }
    if options.missing_flags then api.GetSetTempoTimeSigMarkerFlag = nil end
    local fake_io = { open = function(candidate)
        local output = outputs[candidate]
        if not output then return nil end
        return { close = function() end, seek = function() return #output end, read = function() return output end }
    end }
    local removed_outputs = 0
    local fake_os = setmetatable({ remove = function(candidate)
        assert(outputs[candidate], "Only an existing exact output may be removed")
        outputs[candidate] = nil
        removed_outputs = removed_outputs + 1
        return true
    end }, { __index = os })
    local fake_gfx
    if options.grid then
        local button_x = options.grid == "render_now" and 130 or options.grid == "queue" and 30 or 500
        fake_gfx = {
            mouse_x = button_x, mouse_y = 20, mouse_cap = 1, mouse_wheel = 0,
            init = function(_, width, height) fake_gfx.w, fake_gfx.h = width, height end,
            setfont = function() end, set = function() end, rect = function() end,
            drawstr = function() end, update = function() end, getchar = function() return 0 end,
            quit = function() fake_gfx.closed = true end
        }
    else
        fake_gfx = setmetatable({}, { __index = function() error("GFX accessed on confirmed-row path") end })
    end
    local environment = setmetatable({ reaper = api, io = fake_io, os = fake_os, gfx = fake_gfx }, { __index = _G })
    assert(load(source, "@" .. path, "t", environment))()
    local dispatch_count = 0
    while #deferred > 0 do
        dispatch_count = dispatch_count + 1
        assert(dispatch_count <= 3, "grid did not dispatch the clicked action")
        table.remove(deferred, 1)()
    end
    if options.grid then
        assert(fake_gfx.closed, "clicked grid button must close the grid")
        if options.grid == "cancel" then
            equal(dispatched_options, nil, "Cancel does not dispatch render options")
        else
            assert(dispatched_options and dispatched_options:find("mode=" .. options.grid, 1, true),
                "grid dispatched the clicked execution mode")
        end
    end
    for _, callback in ipairs(exit_callbacks) do callback() end
    equal(removed_outputs, options.preexisting and 3 or 0, "exact existing output removal")
    assert(active_project == (options.tab_switch and other_project or project), "cleanup preserves user active tab")
    equal(points, original_points, "original tempo/meter metadata")
    equal(project_bpm, 120, "original project BPM")
    equal(project_bpi, 5, "original project meter")
    equal(tracks, original_tracks, "original track state")
    equal(regions, original_regions, "original region state")
    equal(numeric, original_numeric, "original numeric render state")
    equal(strings, original_strings, "original string render state")
    local preflight_failure = options.unsupported or options.missing_flags
    local grid_cancel = options.grid == "cancel"
    equal(undo_begin, (preflight_failure or grid_cancel) and 0 or 1, "undo begin count")
    equal(undo_end, (preflight_failure or grid_cancel) and 0 or 1, "undo end count")
    if grid_cancel then
        equal(ext.pending_region_rows_v1, nil, "Cancel stores no pending rows")
    else
        equal(ext.pending_region_rows_v1, "", "consumed pending rows")
    end
    local expected_passes = (preflight_failure or grid_cancel) and 0 or (options.render_error or options.terminate or options.tab_switch) and 1 or options.cancel and 2 or options.click and 4 or options.grid and 9 or 3
    equal(#passes, expected_passes, "render pass count")
    local uses_queue = options.legacy_queue or options.grid == "queue"
    equal(queue_calls, uses_queue and expected_passes or 0, "queue calls")
    equal(render_calls, uses_queue and 0 or expected_passes, "direct render calls")
    for i, pass in ipairs(passes) do
        local is_click = options.click and i == 1
        local regular_index = options.click and i - 1 or i
        local tempo = is_click and 120 or options.grid and 95 + 5 * regular_index or 90 + 10 * regular_index
        equal(pass.bpm, tempo, "effective section tempo in pass " .. i)
        equal(pass.pattern, (is_click and "CLICKDATA/$project_$region_" or "AUDIO/$region/$project_$region_") .. tempo,
            "output pattern in pass " .. i)
        local factor = tempo / 120
        local function at(time)
            for _, point in ipairs(pass.points) do
                if math.abs(point.time - time) < 1e-8 then return point end
            end
            error("missing pass marker at " .. time)
        end
        local expected_start = options.seconds_timebase and region_start or region_start / factor
        equal(pass.region_start, expected_start, "selected region timebase in pass " .. i)
        equal(at(expected_start).bpm, tempo, "tempo override at actual region start in pass " .. i)
        equal(at(expected_start).flags & 2, 0, "temporary explicit region-start tempo in pass " .. i)
        local meter = at(region_start / factor)
        equal(meter.num, 5, "original meter numerator in pass " .. i)
        equal(meter.denom, 4, "original meter denominator in pass " .. i)
        equal(meter.flags, 1, "temporary explicit tempo on original meter-only marker in pass " .. i)
        local ramp = at((4 + region_start) / factor)
        equal(ramp.bpm, 126 * factor, "ramp scaled tempo in pass " .. i)
        equal(ramp.linear, true, "linear tempo ramp in pass " .. i)
        local custom = at((8 + region_start) / factor)
        equal(custom.flags, 29, "custom meter flags in pass " .. i)
        equal(custom.basis, 1.5, "non-quarter beat basis in pass " .. i)
        equal(custom.pattern, "ABBB", "custom metronome pattern in pass " .. i)
        equal(at((12 + region_start) / factor).flags, 7,
            "other meter-only marker retains unchecked Set tempo in pass " .. i)
        equal(pass.tracks[3].B_MUTE, 1, "SOLO muted during pass " .. i)
        equal(pass.tracks[2].B_MUTE, is_click and 0 or 1, "CLICKTRACK mute during pass " .. i)
        if is_click then
            for track_index, track in ipairs(pass.tracks) do
                equal(track.selected, track_index == 2, "click isolation during pass " .. i)
            end
        end
    end
    if preflight_failure then
        local diagnostic = table.concat(messages, "\n") .. "\n" .. table.concat(logs, "\n")
        assert(diagnostic:find(options.unsupported and "6.68" or "GetSetTempoTimeSigMarkerFlag", 1, true),
            "preflight failure surfaced")
    elseif options.render_error or options.terminate or options.tab_switch then
        local diagnostic = table.concat(messages, "\n") .. "\n" .. table.concat(logs, "\n")
        assert(diagnostic:find(options.tab_switch and "active project changed" or options.terminate and "terminated during render" or "injected render failure", 1, true),
            "original error surfaced")
    elseif options.cancel then
        local diagnostic = table.concat(messages, "\n") .. "\n" .. table.concat(logs, "\n")
        assert(diagnostic:lower():find("cancel", 1, true), "cancellation reported")
    else
        equal(#messages, options.grid and not grid_cancel and 2 or 0, "unexpected messages")
    end
    return passes, logs
end

run_case({})
run_case({ legacy_queue = true })
run_case({ region_start = 2 })
run_case({ preexisting = true })
run_case({ region_start = 2, seconds_timebase = true })
run_case({ unsupported = true })
run_case({ missing_flags = true })
run_case({ click = true })
run_case({ render_error = true })
run_case({ cancel = true })
run_case({ terminate = true })
run_case({ tab_switch = true })
run_case({ grid = "render_now" })
run_case({ grid = "queue" })
run_case({ grid = "cancel" })
print("PASS: Tempo Set direct renders, legacy queue, effective tempos at meter-only start, full original-state restoration")
