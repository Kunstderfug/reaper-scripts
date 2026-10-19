-- Run from the repo root: lua tests/click_direct_render.lua
-- Run the actual confirmed-grid render path with an isolated fake project.
local path = "GPhil_click_render_gfx_direct.lua"
local file = assert(io.open(path))
local source = file:read("*a")
file:close()
local section = assert(source:match('local EXT_SECTION%s*=%s*"([^"]+)"'))
local click_preset = "_RSe07780b8d7eb28a48e88b3b7e3467d7c79cade66"

local function copy(values)
    local result = {}
    for key, value in pairs(values) do result[key] = value end
    return result
end

local function assert_equal(actual, expected, label)
    assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
end

local function run_case(options)
    local tracks = {
        { name = "Strings", B_MUTE = 0, I_SOLO = 0, selected = true },
        { name = "CLICKTRACK", B_MUTE = 1, I_SOLO = 0, selected = false },
        { name = "SOLO", B_MUTE = 0, I_SOLO = 0, selected = true },
        { name = "Muted reference", B_MUTE = 1, I_SOLO = 0, selected = false }
    }
    local original_tracks = {}
    for i, track in ipairs(tracks) do original_tracks[i] = copy(track) end
    local regions = {
        { B_ISREGION = 1, B_UISEL = 1, D_STARTPOS = 0, D_ENDPOS = 8, I_NUMBER = 1, name = "Opening" },
        { B_ISREGION = 1, B_UISEL = 0, D_STARTPOS = 8, D_ENDPOS = 16, I_NUMBER = 2, name = "Middle" },
        { B_ISREGION = 1, B_UISEL = 1, D_STARTPOS = 16, D_ENDPOS = 24, I_NUMBER = 3, name = "Ending" },
        { B_ISREGION = 1, B_UISEL = 0, D_STARTPOS = 24, D_ENDPOS = 32, I_NUMBER = 4, name = "Disabled" }
    }
    local original_regions = {}
    for i, region in ipairs(regions) do original_regions[i] = copy(region) end
    local rows = {}
    for i, region in ipairs(regions) do
        local base = i == 3 and 95 or 120
        rows[i] = table.concat({ i - 1, region.D_STARTPOS, region.D_ENDPOS,
            region.name, region.I_NUMBER, base, base, 1, base, 1, i == 4 and 0 or 1 }, "\t")
    end
    local ext = {
        pending_region_rows_v1 = table.concat(rows, "\n"),
        pending_render_options_v1 = "skip_existing=" .. (options.skip_existing and "1" or "0")
    }
    -- Distinct values expose accidental partial restoration after applying a preset.
    local numeric, strings = {}, {}
    for key in source:gmatch('"(RENDER_[A-Z0-9_]+)"') do numeric[key] = #key + 0.125 end
    for _, key in ipairs({ "RENDER_FILE", "RENDER_PATTERN", "RENDER_EXTRAFILEDIR", "RENDER_FORMAT", "RENDER_FORMAT2" }) do
        numeric[key] = nil
        strings[key] = "original-" .. key
    end
    local original_numeric, original_strings = copy(numeric), copy(strings)
    local passes, messages, logs = {}, {}, {}
    local tempo_writes, queue_calls, preset_calls = 0, 0, 0
    local undo_begin, undo_end = 0, 0
    local function forbid_tempo_write()
        tempo_writes = tempo_writes + 1
        error("tempo map was mutated")
    end
    local api = {
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
        GetRegionOrMarker = function(_, index) return regions[index + 1] end,
        GetRegionOrMarkerInfo_Value = function(_, region, key) return assert(region[key], key) end,
        SetRegionOrMarkerInfo_Value = function(_, region, key, value) region[key] = value; return true end,
        GetSetRegionOrMarkerInfo_String = function(_, region) return true, region.name end,
        GetProjExtState = function(_, requested_section, key)
            assert_equal(requested_section, section, "project state section")
            return ext[key] and 1 or 0, ext[key] or ""
        end,
        SetProjExtState = function(_, requested_section, key, value)
            assert_equal(requested_section, section, "project state section")
            ext[key] = value
            return 1
        end,
        GetSetProjectInfo = function(_, key, value, set)
            if set then numeric[key] = value end
            return assert(numeric[key], key)
        end,
        GetSetProjectInfo_String = function(_, key, value, set)
            if set then strings[key] = value end
            return true, assert(strings[key], key)
        end,
        GetProjectPathEx = function() return "/fake-project" end,
        GetProjectName = function() return "Suite.rpp" end,
        NamedCommandLookup = function(command)
            assert_equal(command, click_preset, "GPHIL_CLICK preset action")
            return 9876
        end,
        Main_OnCommand = function(command)
            if command == 40297 then
                for _, track in ipairs(tracks) do track.selected = false end
            elseif command == 9876 then
                preset_calls = preset_calls + 1
                for key in pairs(numeric) do numeric[key] = 123 end
                for key in pairs(strings) do strings[key] = "preset-" .. key end
                numeric.RENDER_SETTINGS = 3 -- Selected-track source in the user's click preset.
                strings.RENDER_FILE = "/fake-output"
            elseif command == 41823 then
                queue_calls = queue_calls + 1
                error("click-only direct render must never queue")
            elseif command == 42230 then
                assert(tracks[2].selected and tracks[2].B_MUTE == 0, "click must be selected and unmuted")
                for i, track in ipairs(tracks) do
                    if i ~= 2 then assert(not track.selected, "non-click track selected: " .. track.name) end
                end
                assert_equal(numeric.RENDER_BOUNDSFLAG, 5, "selected-region bounds")
                assert_equal(numeric.RENDER_SETTINGS, 3, "selected-track preset retained")
                local selected = {}
                for i, region in ipairs(regions) do
                    if region.B_UISEL > 0.5 then selected[#selected + 1] = i end
                end
                passes[#passes + 1] = { pattern = strings.RENDER_PATTERN, selected = table.concat(selected, ",") }
                if options.render_error then error("injected render failure") end
            else
                error("unexpected command: " .. tostring(command))
            end
        end,
        Undo_BeginBlock = function() undo_begin = undo_begin + 1 end,
        Undo_EndBlock = function() undo_end = undo_end + 1 end,
        UpdateArrange = function() end,
        ShowConsoleMsg = function(message) logs[#logs + 1] = message end,
        ShowMessageBox = function(message) messages[#messages + 1] = message; return 1 end,
        defer = function() error("confirmed rows should not open the grid") end,
        SetTempoTimeSigMarker = forbid_tempo_write,
        DeleteTempoTimeSigMarker = forbid_tempo_write,
        SetCurrentBPM = forbid_tempo_write,
        GetSetTempoTimeSigMarkerFlag = function(_, _, _, set)
            if set then forbid_tempo_write() end
            return 1
        end
    }
    local fake_io = { open = function(candidate)
        if options.skip_existing and candidate == "/fake-output/CLICKDATA/Suite_Opening_120.wav" then
            return { close = function() end }
        end
        return nil
    end }
    local environment = setmetatable({ reaper = api, io = fake_io,
        gfx = setmetatable({}, { __index = function() error("GFX accessed on confirmed-row path") end }) }, { __index = _G })
    assert(load(source, "@" .. path, "t", environment))()
    for i, track in ipairs(tracks) do
        for key, value in pairs(original_tracks[i]) do assert_equal(track[key], value, "restored track " .. i .. " " .. key) end
    end
    for i, region in ipairs(regions) do assert_equal(region.B_UISEL, original_regions[i].B_UISEL, "restored region " .. i) end
    for key, value in pairs(original_numeric) do assert_equal(numeric[key], value, "restored numeric " .. key) end
    for key, value in pairs(original_strings) do assert_equal(strings[key], value, "restored string " .. key) end
    assert_equal(tempo_writes, 0, "tempo/meter writes")
    assert_equal(queue_calls, 0, "queue action calls")
    assert_equal(undo_begin, 1, "undo begin")
    assert_equal(undo_end, 1, "undo end")
    assert_equal(ext.pending_region_rows_v1, "", "consumed confirmed rows")
    assert_equal(#passes, options.render_error and 1 or 2, "same-base render grouping")
    assert_equal(passes[1].pattern, "CLICKDATA/$project_$region_120", "first click output pattern")
    assert_equal(passes[1].selected, options.skip_existing and "2" or "1,2", "first selected regions")
    if options.render_error then
        assert_equal(#messages, 1, "reported render error")
        assert(messages[1]:find("injected render failure", 1, true), "original render error reported")
    else
        assert_equal(#messages, 0, "no unexpected message boxes")
        assert_equal(passes[2].pattern, "CLICKDATA/$project_$region_95", "second click output pattern")
        assert_equal(passes[2].selected, "3", "second selected regions; disabled row excluded")
    end
    assert_equal(preset_calls, #passes, "click preset for each render group")
end

run_case({})
run_case({ skip_existing = true })
run_case({ render_error = true })
print("PASS: click direct render groups, track isolation, click paths, skip-existing, unchanged tempo map, and success/error restoration")
