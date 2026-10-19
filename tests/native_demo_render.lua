-- Native integration test for the portable Tempo Set Demo. Run only through
-- the mailbox of the disposable /tmp/gphil-native-multiregion-* REAPER host.
-- The real renderer and Tempo Set source/modules run; only preset application,
-- confirmed grid input, and notification collection are adapted. Never saves.
local native = reaper
if not native then print('SKIP native_demo_render: requires disposable REAPER host'); return end
local root = native.GetResourcePath()
assert(root:match('^/tmp/gphil%-native%-multiregion%-[^/]+$'), 'Not disposable resources')
local sentinel = assert(io.open(root .. '/gphil-disposable-native-test')); sentinel:close()
local test_path = debug.getinfo(1, 'S').source:sub(2)
local repo = assert(test_path:match('^(.*[/\\])tests[/\\]'))
local demo_path = repo .. 'examples/tempo-set-demo/Tempo Set Demo.rpp'
local proj, filename = native.EnumProjects(-1, '')
assert(filename == demo_path and native.CountTracks(proj) == 2, 'Not demo project')
local music, click = native.GetTrack(proj, 0), native.GetTrack(proj, 1)
local _, music_name = native.GetTrackName(music, '')
local _, click_name = native.GetTrackName(click, '')
assert(music_name == 'DEMO MUSIC' and click_name == 'CLICKTRACK', 'Not demo tracks')

local report = assert(io.open(root .. '/demo-render.txt', 'w'))
local function log(value) report:write(value .. '\n'); report:flush() end
local function equal(a, b, label)
    if type(a) == 'table' then
        assert(type(b) == 'table', label)
        for key, value in pairs(a) do equal(value, b[key], label .. '.' .. tostring(key)) end
        for key in pairs(b) do assert(a[key] ~= nil, label .. ': unexpected ' .. tostring(key)) end
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
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do result[#result + 1] = tostring(key) .. '=' .. dump(value[key]) end
    return '{' .. table.concat(result, ',') .. '}'
end
local function split(value)
    local result = {}
    for part in value:gmatch('[^;]+') do result[#result + 1] = part end
    return result
end

local ok, err = xpcall(function()
    local source_file = assert(io.open(repo .. 'GPhil_tempoSet_render_gfx_direct.lua'))
    local source = source_file:read('*a'); source_file:close()
    local map = dofile(repo .. 'lib/tempo_map.lua').new(native)
    local original_map = map.capture(proj)
    assert(#original_map.markers == 5, 'Expected all five demo tempo/meter marks')
    assert(original_map.markers[4].flags & 2 ~= 0, 'Region B must begin with meter-only mark')
    equal(native.GetMediaTrackInfo_Value(click, 'B_MUTE'), 1, 'Click muted by default')
    local function regions()
        local result = {}
        for i = 0, 1 do
            local region = assert(native.GetRegionOrMarker(proj, i, ''))
            local row = {}
            for _, key in ipairs({ 'D_STARTPOS', 'D_ENDPOS', 'B_UISEL', 'I_NUMBER' }) do
                row[key] = native.GetRegionOrMarkerInfo_Value(proj, region, key)
            end
            result[#result + 1] = row
        end
        return result
    end
    local function tracks()
        local result = {}
        for i, track in ipairs({ music, click }) do
            result[i] = { selected = native.IsTrackSelected(track),
                mute = native.GetMediaTrackInfo_Value(track, 'B_MUTE') }
        end
        return result
    end
    local function items()
        local result = {}
        for i = 0, native.CountMediaItems(proj) - 1 do
            local item = native.GetMediaItem(proj, i)
            result[i + 1] = { position = native.GetMediaItemInfo_Value(item, 'D_POSITION'),
                length = native.GetMediaItemInfo_Value(item, 'D_LENGTH'),
                rate = native.GetMediaItemTakeInfo_Value(native.GetActiveTake(item), 'D_PLAYRATE') }
        end
        return result
    end
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
    local original_regions, original_tracks = regions(), tracks()
    local original_render, original_items = render_settings(), items()
    local saved_ok, saved_rows = native.GetProjExtState(proj, 'renderTempoSet', 'saved_region_rows_v1')
    assert(saved_ok == 1 and saved_rows ~= '', 'Demo saved grid settings missing')
    local plan = {
        { region = 1, name = 'Region_A', base = 120, target = 120, click = true },
        { region = 2, name = 'Region_B', base = 90, target = 90, click = true },
        { region = 1, name = 'Region_A', base = 120, target = 100 },
        { region = 1, name = 'Region_A', base = 120, target = 120 },
        { region = 2, name = 'Region_B', base = 90, target = 80 },
        { region = 2, name = 'Region_B', base = 90, target = 90 }
    }
    local attempts, notices, callbacks, all_targets = {}, {}, {}, {}
    local output_dir = root .. '/demo-output'
    local api = setmetatable({}, { __index = native })
    api.NamedCommandLookup = function(command)
        if command == '_RS67c8ada3573313a7c135385939c19cbc2450964d' then return 900001 end
        if command == '_RSe07780b8d7eb28a48e88b3b7e3467d7c79cade66' then return 900002 end
        return native.NamedCommandLookup(command)
    end
    api.Main_OnCommand = function(command, flag)
        if command ~= 900001 and command ~= 900002 then return native.Main_OnCommand(command, flag) end
        -- Official GetSetProjectInfo docs: &128=selected tracks via master;
        -- &32 means selected MEDIA ITEMS, so it cannot isolate this click track.
        -- https://www.reaper.fm/sdk/reascript/reascripthelp.html#GetSetProjectInfo
        for key, value in pairs({ RENDER_SETTINGS = command == 900002 and 128 or 0,
            RENDER_BOUNDSFLAG = 3, RENDER_CHANNELS = 1, RENDER_SRATE = 44100,
            RENDER_ADDTOPROJ = 0, RENDER_TAILFLAG = 0 }) do
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
        local region, original = live_regions[entry.region], original_regions[entry.region]
        equal(native.TimeMap2_GetDividedBpmAtTime(proj, region.D_STARTPOS), entry.target, 'Live region tempo')
        equal(region.D_ENDPOS - region.D_STARTPOS,
            (original.D_ENDPOS - original.D_STARTPOS) * entry.base / entry.target, 'Scaled region duration')
        equal(native.GetMediaTrackInfo_Value(click, 'B_MUTE'), entry.click and 0 or 1, 'Live click mute')
        if entry.click then
            equal(native.IsTrackSelected(click), true, 'Click exclusively selected')
            equal(native.IsTrackSelected(music), false, 'Music excluded from click render')
        end
        equal(native.GetSetProjectInfo(proj, 'RENDER_SETTINGS', 0, false), entry.click and 128 or 0,
            'Native render source')
        local found, targets_blob = native.GetSetProjectInfo_String(p, 'RENDER_TARGETS', '', false)
        assert(found and targets_blob ~= '', 'Native target list missing')
        local targets = split(targets_blob)
        equal(#targets, 2, 'Primary and secondary native outputs')
        log('START ' .. (entry.click and 'CLICK ' or 'AUDIO ') .. entry.name .. ' target=' .. entry.target)
        for _, target in ipairs(targets) do
            assert(target:sub(1, #output_dir + 1) == output_dir .. '/', 'Output escaped disposable folder')
            assert(target:find(entry.name, 1, true), 'Wrong region target')
            assert(target:match('_' .. entry.target .. '%.[%a%d]+$'), 'Wrong tempo suffix')
            assert(not all_targets[target], 'Output unexpectedly reused')
            all_targets[target] = true
            log('TARGET ' .. target)
        end
        local success, stats = native.GetSetProjectInfo_String(p, key, value, set)
        attempts[#attempts + 1] = stats
        log('STATS ' .. tostring(stats))
        assert(success and stats ~= '', 'Native render canceled or failed')
        local peak = tonumber(stats:match('PEAK:([%-%.%d]+)'))
        assert(peak and peak > -90, 'Rendered output is silent')
        for _, target in ipairs(targets) do
            local rendered = assert(io.open(target, 'rb'), 'Native output missing')
            local header = rendered:read(4); rendered:close()
            local ext = target:match('%.([%a%d]+)$')
            assert(ext == 'ogg' or ext == 'flac', 'Unexpected native encoding')
            equal(header, ext == 'ogg' and 'OggS' or 'fLaC', 'Encoded output header')
        end
        return success, stats
    end
    api.ShowConsoleMsg = function(message) log(message:gsub('\n$', '')) end
    api.ShowMessageBox = function(message) notices[#notices + 1] = message; log('MESSAGE ' .. message); return 1 end
    api.atexit = function(fn) callbacks[#callbacks + 1] = fn end
    native.SetProjExtState(proj, 'renderTempoSet', 'pending_region_rows_v1', saved_rows)
    native.SetProjExtState(proj, 'renderTempoSet', 'pending_queue_options_v1', 'skip_existing=0\nmode=render_now')
    log('HOST ' .. native.GetAppVersion())
    log('ORIGINAL_MAP ' .. dump(original_map))
    local environment = setmetatable({ reaper = api }, { __index = _G })
    assert(load(source, '@' .. repo .. 'GPhil_tempoSet_render_gfx_direct.lua', 't', environment))()
    for _, fn in ipairs(callbacks) do fn() end -- Exit cleanup must be idempotent.
    local restored_map = map.capture(proj)
    log('RESTORED_MAP ' .. dump(restored_map))
    equal(original_map, restored_map, 'Original tempo/meter map')
    equal(original_regions, regions(), 'Original region bounds and selections')
    equal(original_tracks, tracks(), 'Both original track states')
    equal(original_render, render_settings(), 'Original render settings')
    equal(original_items, items(), 'Original item positions, lengths and rates')
    local _, restored_rows = native.GetProjExtState(proj, 'renderTempoSet', 'saved_region_rows_v1')
    equal(saved_rows, restored_rows, 'Original saved grid settings')
    equal(#attempts, 6, 'Two click and four regular render passes')
    equal(#notices, 0, 'Unexpected failure notice')
    local count = 0
    for _ in pairs(all_targets) do count = count + 1 end
    equal(count, 12, 'Twelve encoded native output files')
    log('PASS demo: six native passes, twelve non-silent Ogg/FLAC files; full map, regions, tracks, items and settings restored')
end, debug.traceback)
if not ok then log('FAIL ' .. tostring(err)) end
report:close()
