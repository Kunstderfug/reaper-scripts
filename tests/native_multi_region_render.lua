-- Native smoke test: run ONLY in a disposable REAPER instance whose resource
-- path is /tmp/gphil-native-multiregion-* and contains the sentinel below.
-- Requires fixture.rpp with one track named GPhil disposable fixture, and SWS.
-- Set GPHIL_NATIVE_TEST_PHASE to success, overwrite, cancel_keep, or cancel_discard.
-- Cancel phases use a long second region: click native Cancel on its first pass.
-- This executes the real Tempo Set source/modules and renderer. Only preset
-- application, confirmed grid inputs, and message collection are adapted.
local native = reaper
if not native then print('SKIP native_multi_region_render: requires disposable REAPER host'); return end
local root = native.GetResourcePath()
assert(root:match('^/tmp/gphil%-native%-multiregion%-[^/]+$'), 'Not disposable resources')
local sentinel = assert(io.open(root .. '/gphil-disposable-native-test'))
sentinel:close()
local proj, filename = native.EnumProjects(-1, '')
assert(filename == root .. '/fixture.rpp' and native.CountTracks(proj) == 1, 'Not fixture project')
local _, track_name = native.GetTrackName(native.GetTrack(proj, 0))
assert(track_name == 'GPhil disposable fixture', 'Not fixture track')
assert(native.SNM_SetIntConfigVar and native.SNM_GetIntConfigVar, 'SWS required by fixture')

local source_path = debug.getinfo(1, 'S').source:sub(2)
local repo = assert(source_path:match('^(.*[/\\])tests[/\\]'))
local phase = GPHIL_NATIVE_TEST_PHASE or 'success'
assert(phase == 'success' or phase == 'overwrite' or phase == 'cancel_keep' or phase == 'cancel_discard')
local cancel = phase:match('^cancel') ~= nil
local report = assert(io.open(root .. '/' .. phase .. '.txt', 'w'))
local function log(value) report:write(value .. '\n'); report:flush() end
local function equal(a, b, label)
    if type(a) == 'table' then
        assert(type(b) == 'table', label)
        for k, v in pairs(a) do equal(v, b[k], label .. '.' .. tostring(k)) end
        for k in pairs(b) do assert(a[k] ~= nil, label .. ': unexpected ' .. tostring(k)) end
    elseif type(a) == 'number' then
        assert(type(b) == 'number' and math.abs(a - b) <= 1e-6,
            label .. ': ' .. tostring(a) .. ' differs from ' .. tostring(b))
    else
        assert(a == b, label .. ': ' .. tostring(a) .. ' differs from ' .. tostring(b))
    end
end
local function dump(value)
    if type(value) ~= 'table' then return string.format('%q', tostring(value)) end
    local keys, result = {}, {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do result[#result + 1] = tostring(k) .. '=' .. dump(value[k]) end
    return '{' .. table.concat(result, ',') .. '}'
end

local ok, err = xpcall(function()
    for i = native.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do
        assert(native.DeleteTempoTimeSigMarker(proj, i))
    end
    native.SetCurrentBPM(proj, 120, false)
    assert(native.SNM_SetIntConfigVar('projmeaslen', 4))
    assert(native.SNM_SetIntConfigVar('projtsdenom', 4))
    assert(native.SNM_SetIntConfigVar('itemtimelock', 1))
    equal(native.GetSetProjectInfo(proj, 'PROJECT_TIMEBASE', 0, false), 1, 'Fixture beats timebase')
    local specs = {
        { 0, 120, 4, 4, 1 }, { 1, 120, 5, 4, 11 },
        { 2, 90, 0, 0, 0 }, { 3, 90, 3, 4, 3 }, { 4, 90, 6, 8, 3 }
    }
    for i, spec in ipairs(specs) do
        assert(native.SetTempoTimeSigMarker(proj, -1, -1, spec[1], 0, spec[2], spec[3], spec[4], false))
        if spec[5] & 8 ~= 0 then
            local _, time = native.GetTempoTimeSigMarker(proj, i - 1)
            native.TimeMap_GetMetronomePattern(proj, time, 'SET:ABBBB')
        end
        native.GetSetTempoTimeSigMarkerFlag(proj, i - 1, spec[5], true)
    end
    native.UpdateTimeline()
    assert(native.CountTempoTimeSigMarkers(proj) == #specs, 'Fixture insertion lost a marker')
    local _, b_start = native.GetTempoTimeSigMarker(proj, 3)
    local _, a_end = native.GetTempoTimeSigMarker(proj, 2)
    local _, b_end = native.GetTempoTimeSigMarker(proj, 4)
    if cancel then b_end = b_start + 144000 end
    native.DeleteProjectMarker(proj, 1, true)
    native.DeleteProjectMarker(proj, 2, true)
    assert(native.AddProjectMarker2(proj, true, 0, a_end, 'Region_A', 1, 0) == 1)
    assert(native.AddProjectMarker2(proj, true, b_start, b_end, 'Region_B', 2, 0) == 2)
    native.SetRegionOrMarkerInfo_Value(proj, native.GetRegionOrMarker(proj, 0, ""), 'B_UISEL', 1)
    native.SetRegionOrMarkerInfo_Value(proj, native.GetRegionOrMarker(proj, 1, ""), 'B_UISEL', 0)
    local map = dofile(repo .. 'lib/tempo_map.lua').new(native)
    local original_map = map.capture(proj)
    assert(original_map.markers[4].flags & 2 ~= 0, 'Region B must start at a meter-only point')
    local function regions()
        local result = {}
        for i = 0, 1 do
            local r = native.GetRegionOrMarker(proj, i, "")
            local row = {}
            for _, key in ipairs({ 'D_STARTPOS', 'D_ENDPOS', 'B_UISEL', 'I_NUMBER' }) do
                row[key] = native.GetRegionOrMarkerInfo_Value(proj, r, key)
            end
            result[#result + 1] = row
        end
        return result
    end
    local original_regions = regions()
    local source_file = assert(io.open(repo .. 'GPhil_tempoSet_render_gfx_direct.lua'))
    local source = source_file:read('*a'); source_file:close()
    local function render_settings()
        local result = {}
        for key in source:gmatch('"(RENDER_[A-Z0-9_]+)"') do
            if key ~= 'RENDER_TARGETS' and key ~= 'RENDER_STATS' then
                if key == 'RENDER_FILE' or key == 'RENDER_PATTERN' or key == 'RENDER_EXTRAFILEDIR'
                    or key == 'RENDER_FORMAT' or key == 'RENDER_FORMAT2' then
                    local success, value = native.GetSetProjectInfo_String(proj, key, '', false)
                    assert(success, key); result[key] = value
                else result[key] = native.GetSetProjectInfo(proj, key, 0, false) end
            end
        end
        return result
    end
    local original_render = render_settings()
    local track = native.GetTrack(proj, 0)
    local original_track = { native.IsTrackSelected(track), native.GetMediaTrackInfo_Value(track, 'B_MUTE') }
    local output_dir = root .. (cancel and '/cancel-output' or '/output')
    local plan = {
        { region = 1, name = 'Region_A', base = 120, target = 100 },
        { region = 1, name = 'Region_A', base = 120, target = 120 },
        { region = 2, name = 'Region_B', base = 90, target = 80 },
        { region = 2, name = 'Region_B', base = 90, target = 90 }
    }
    local function path(entry, ext)
        return output_dir .. '/AUDIO/' .. entry.name .. '/fixture_' .. entry.name .. '_' .. entry.target .. '.' .. ext
    end
    if phase == 'overwrite' then
        for _, entry in ipairs(plan) do
            for _, ext in ipairs({ 'ogg', 'flac' }) do
                local file = assert(io.open(path(entry, ext), 'wb'), 'Success phase must run first')
                file:write('overwrite sentinel'); file:close()
            end
        end
    end
    local sibling = root .. '/unrelated.txt'
    local file = assert(io.open(sibling, 'w')); file:write('preserve me'); file:close()
    local attempts, notices, callbacks = {}, {}, {}
    local api = setmetatable({}, { __index = native })
    api.NamedCommandLookup = function(command)
        if command == '_RS67c8ada3573313a7c135385939c19cbc2450964d' then return 900001 end
        return native.NamedCommandLookup(command)
    end
    api.Main_OnCommand = function(command, flag)
        if command ~= 900001 then return native.Main_OnCommand(command, flag) end
        for key, value in pairs({ RENDER_SETTINGS = 0, RENDER_BOUNDSFLAG = 3, RENDER_CHANNELS = 1,
            RENDER_SRATE = 44100, RENDER_ADDTOPROJ = 0, RENDER_TAILFLAG = 0 }) do
            native.GetSetProjectInfo(proj, key, value, true)
        end
        native.GetSetProjectInfo_String(proj, 'RENDER_FILE', output_dir, true)
        native.GetSetProjectInfo_String(proj, 'RENDER_FORMAT', 'dmdnb2ZmZj8AGAAAAIAAAAAgAAAAAAEAAA', true)
        native.GetSetProjectInfo_String(proj, 'RENDER_FORMAT2', 'Y2FsZhgAAAAIAAAA', true)
    end
    api.GetSetProjectInfo_String = function(p, key, value, set)
        if key ~= 'RENDER_STATS' then return native.GetSetProjectInfo_String(p, key, value, set) end
        local entry = assert(plan[#attempts + 1], 'Unexpected extra render')
        local live_regions = regions()
        for i, region in ipairs(live_regions) do
            equal(region.B_UISEL, i == entry.region and 1 or 0, 'Selected render region')
        end
        local region = live_regions[entry.region]
        equal(native.TimeMap2_GetDividedBpmAtTime(proj, region.D_STARTPOS), entry.target, 'Live region tempo')
        local original = original_regions[entry.region]
        equal(region.D_ENDPOS - region.D_STARTPOS,
            (original.D_ENDPOS - original.D_STARTPOS) * entry.base / entry.target, 'Scaled region duration')
        log('START ' .. entry.name .. ' base=' .. entry.base .. ' target=' .. entry.target)
        local success, stats = native.GetSetProjectInfo_String(p, key, value, set)
        attempts[#attempts + 1] = stats
        log('STATS ' .. tostring(stats))
        if stats ~= '' then
            for _, ext in ipairs({ 'ogg', 'flac' }) do
                local rendered_file = assert(io.open(path(entry, ext), 'rb'), 'Missing rendered file')
                local header = rendered_file:read(4); rendered_file:close()
                equal(header, ext == 'ogg' and 'OggS' or 'fLaC', 'Encoded file header')
            end
        end
        return success, stats
    end
    api.ShowConsoleMsg = function(message) log(message:gsub('\n$', '')) end
    api.ShowMessageBox = function(message) notices[#notices + 1] = message; log('MESSAGE ' .. message); return 1 end
    api.atexit = function(fn) callbacks[#callbacks + 1] = fn end
    local rows = {
        table.concat({ 0, 0, a_end, 'Region_A', 1, 120, 100, 20, 120, 0, 1 }, '\t'),
        table.concat({ 1, b_start, b_end, 'Region_B', 2, 90, 80, 10, 90, 0, 1 }, '\t')
    }
    native.SetProjExtState(proj, 'renderTempoSet', 'pending_region_rows_v1', table.concat(rows, '\n'))
    native.SetProjExtState(proj, 'renderTempoSet', 'pending_queue_options_v1', 'skip_existing=0\nmode=render_now')
    log('HOST ' .. native.GetAppVersion())
    log('ORIGINAL_MAP ' .. dump(original_map))
    local environment = setmetatable({ reaper = api }, { __index = _G })
    assert(load(source, '@' .. repo .. 'GPhil_tempoSet_render_gfx_direct.lua', 't', environment))()
    for _, fn in ipairs(callbacks) do fn() end -- Confirm exit cleanup is idempotent.
    local restored_map = map.capture(proj)
    log('RESTORED_MAP ' .. dump(restored_map))
    equal(original_map, restored_map, 'Original tempo/meter map')
    equal(original_regions, regions(), 'Original region bounds and selections')
    equal(original_render, render_settings(), 'Original render settings')
    equal(original_track, { native.IsTrackSelected(track), native.GetMediaTrackInfo_Value(track, 'B_MUTE') }, 'Track state')
    local sibling_file = assert(io.open(sibling)); equal(sibling_file:read('*a'), 'preserve me', 'Unrelated file'); sibling_file:close()
    if cancel then
        equal(#attempts, 3, 'Cancel must prevent fourth render')
        equal(attempts[3], '', 'Native cancel returns empty statistics')
        assert(table.concat(notices):find('canceled or failed'), 'Cancellation not reported')
    else
        equal(#attempts, 4, 'All region/tempo passes')
        equal(#notices, 0, 'Unexpected failure notice')
    end
    log('PASS ' .. phase .. ': outputs, live tempos, complete map, region bounds, render settings and track state')
end, debug.traceback)
if not ok then log('FAIL ' .. tostring(err)) end
report:close()
