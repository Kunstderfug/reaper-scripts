-- Run the real picker, tempo grid and queue continuation against a fake project.
local path = './GPhil_renderStems_queue_gfx_direct.lua'
local file = assert(io.open(path))
local source = file:read('*a')
file:close()

local function clone(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for key, item in pairs(value) do copy[key] = clone(item) end
    return copy
end

local function equal(actual, expected, label)
    if type(expected) ~= 'table' then
        assert(actual == expected, label .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
        return
    end
    assert(type(actual) == 'table', label)
    for key, value in pairs(expected) do equal(actual[key], value, label .. '.' .. tostring(key)) end
    for key in pairs(actual) do assert(expected[key] ~= nil, label .. ': unexpected ' .. tostring(key)) end
end

local function run_case(mode)
    local project, active, deferred = {}, nil, {}
    active = project
    local tracks = {
        { name = 'Original', selected = true }, { name = 'CLICKTRACK', B_MUTE = 1 },
        { name = 'SOLO' }, { name = 'STEMS', I_FOLDERDEPTH = 1, B_MUTE = 1 },
        { name = 'orch', I_FOLDERDEPTH = 1, B_MUTE = 1 },
        { name = 'w', I_FOLDERDEPTH = 1, B_MUTE = 1 },
        { name = 'fl', B_MUTE = 1 }, { name = 'ob', I_FOLDERDEPTH = -2, B_MUTE = 1 },
        { name = 'band', I_FOLDERDEPTH = 1, B_MUTE = 1 },
        { name = 'sx', I_FOLDERDEPTH = -2, B_MUTE = 1 },
        { name = 'W_STEM', B_MUTE = 1 },
    }
    for i, track in ipairs(tracks) do
        track.guid, track.selected = '{' .. i .. '}', track.selected or false
        track.I_FOLDERDEPTH, track.B_MUTE = track.I_FOLDERDEPTH or 0, track.B_MUTE or 0
    end
    local original_tracks = clone(tracks)
    local regions = {
        { B_ISREGION = 1, B_UISEL = 0, D_STARTPOS = 0, D_ENDPOS = 8, I_NUMBER = 1, name = 'Opening' },
    }
    local original_regions = clone(regions)
    local points = { { time = 0, bpm = 120, num = 4, denom = 4, linear = false, flags = 1 } }
    local original_points = clone(points)
    local numeric, strings, ext = {}, {}, {}
    if mode == 'saved_guids' then
        ext['GPHIL_STEM_LAYERS/selected_guids'] = '{6}\n{7}\n{removed}\n{1}\n{11}\n{4}\n{5}'
    end
    for key in source:gmatch('"(RENDER_[A-Z0-9_]+)"') do numeric[key] = 17 end
    for _, key in ipairs({ 'RENDER_FILE', 'RENDER_PATTERN', 'RENDER_EXTRAFILEDIR', 'RENDER_FORMAT', 'RENDER_FORMAT2' }) do
        numeric[key], strings[key] = nil, 'original-' .. key
    end
    local original_numeric, original_strings = clone(numeric), clone(strings)
    local queued, errors, edits = {}, {}, 0
    local mutations, ext_writes, undo_begin, undo_end, tick = 0, 0, 0, 0, 0
    local rendered_count, picker_labels = nil, {}
    local gfx = { mouse_x = 0, mouse_y = 0, mouse_cap = 0, mouse_wheel = 0 }
    gfx.init = function(title, width, height) gfx.title, gfx.w, gfx.h = title, width, height end
    for _, name in ipairs({ 'set', 'rect', 'setfont', 'drawstr', 'update', 'quit' }) do gfx[name] = function() end end
    gfx.drawstr = function(value)
        local count = value:match('^(%d+) layer%(s%) enabled$')
        if count then rendered_count = tonumber(count) end
        if gfx.title == 'Stem render layers' then picker_labels[value] = true end
    end
    gfx.getchar = function() return 0 end
    gfx.measurestr = function(text) return #text * 7 end
    local function check_project(p) assert(p == project, 'Wrong project') end
    local api = {
        EnumProjects = function() return active, '/fake/Beethoven.RPP' end,
        CountTracks = function(p) check_project(p); return #tracks end,
        GetTrack = function(p, i) check_project(p); return tracks[i + 1] end,
        GetTrackGUID = function(t) return t.guid end,
        GetTrackName = function(t) return true, t.name end,
        GetMediaTrackInfo_Value = function(t, key) return t[key] or 0 end,
        SetMediaTrackInfo_Value = function(t, key, value) t[key] = value; mutations = mutations + 1; return true end,
        IsTrackSelected = function(t) return t.selected end,
        SetTrackSelected = function(t, value) t.selected = value; mutations = mutations + 1 end,
        ValidatePtr2 = function(p, t) return (p == project or p == 0) and not t.deleted end,
        GetNumRegionsOrMarkers = function() return #regions end,
        GetRegionOrMarker = function(_, i) return regions[i + 1] end,
        GetRegionOrMarkerInfo_Value = function(_, region, key) return assert(region[key], key) end,
        SetRegionOrMarkerInfo_Value = function(_, region, key, value) region[key] = value; return true end,
        GetSetRegionOrMarkerInfo_String = function(_, region) return true, region.name end,
        EnumProjectMarkers3 = function(_, i)
            local region = regions[i + 1]
            if not region then return 0 end
            return 1, true, region.D_STARTPOS, region.D_ENDPOS, region.name, region.I_NUMBER, 0
        end,
        GetProjExtState = function(p, section, key)
            check_project(p)
            local value = ext[section .. '/' .. key]
            return value and 1 or 0, value or ''
        end,
        SetProjExtState = function(p, section, key, value)
            check_project(p)
            ext_writes = ext_writes + 1
            ext[section .. '/' .. key] = value
            return 1
        end,
        TimeMap2_GetDividedBpmAtTime = function() return 120 end,
        CountTempoTimeSigMarkers = function() return #points end,
        GetTempoTimeSigMarker = function(_, i)
            local point = points[i + 1]
            return true, point.time, -1, -1, point.bpm, point.num, point.denom, point.linear
        end,
        DeleteTempoTimeSigMarker = function(_, i) table.remove(points, i + 1); return true end,
        SetTempoTimeSigMarker = function(_, i, time, _, _, bpm, num, denom, linear)
            local point = { time = time, bpm = bpm, num = num, denom = denom, linear = linear, flags = 0 }
            if i == -1 then points[#points + 1] = point else points[i + 1] = point end
            table.sort(points, function(a, b) return a.time < b.time end)
            return true
        end,
        GetSetTempoTimeSigMarkerFlag = function(_, i, value, set)
            if set then points[i + 1].flags = value end
            return points[i + 1].flags
        end,
        GetSetProjectInfo = function(_, key, value, set)
            if set then numeric[key] = value end
            return assert(numeric[key], key)
        end,
        GetSetProjectInfo_String = function(_, key, value, set)
            if set then strings[key] = value end
            return true, assert(strings[key], key)
        end,
        GetProjectPathEx = function() return '/fake' end,
        GetProjectName = function() return 'Beethoven.RPP' end,
        NamedCommandLookup = function(id)
            if id == '_RSa8c57e22cbf0ac88d95a5178ce4ede7f039e74a2' then return 9001 end
            if id == '_RSe07780b8d7eb28a48e88b3b7e3467d7c79cade66' then return 9002 end
            error('Unexpected action ' .. id)
        end,
        Main_OnCommand = function(command)
            assert(active == project, 'Action affected another project')
            if command == 40297 then
                for _, track in ipairs(tracks) do track.selected = false end
            elseif command == 9001 or command == 9002 then
                numeric.RENDER_SETTINGS, strings.RENDER_FILE = command, '/fake-output'
            elseif command == 41823 then
                queued[#queued + 1] = { tracks = clone(tracks), pattern = strings.RENDER_PATTERN,
                    region = clone(regions[1]), bpm = points[1].bpm }
                if mode == 'queue_error' then error('Injected queue failure') end
            else error('Unexpected command ' .. tostring(command)) end
        end,
        Undo_BeginBlock = function() undo_begin = undo_begin + 1 end,
        Undo_EndBlock = function() undo_end = undo_end + 1 end,
        UpdateArrange = function() end,
        ShowConsoleMsg = function() end,
        ShowMessageBox = function(message, title)
            if title == 'Queue Preview' then return 1 end
            if title == 'Existing Files' then return 6 end
            errors[#errors + 1] = message
            return 1
        end,
        GetUserInputs = function(_, _, label)
            assert(label == 'Min tempo' or label == 'Max tempo')
            edits = edits + 1
            return true, '110'
        end,
        defer = function(callback) deferred[#deferred + 1] = callback end,
        time_precise = function() tick = tick + 0.1; return tick end,
    }
    local environment = setmetatable({ reaper = api, gfx = gfx,
        io = { open = function() return nil end } }, { __index = _G })
    assert(load(source, '@' .. path, 't', environment))()
    local function frame(x, y, down)
        gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap = x or 0, y or 0, down and 1 or 0
        assert(#deferred == 1, 'Expected exactly one modeless continuation')
        table.remove(deferred, 1)()
    end
    local function click(x, y) frame(x, y, true); frame(x, y, false) end
    local function attempt_in_other_project(actions)
        local before_writes, before_mutations, before_edits = ext_writes, mutations, edits
        local before_ext = clone(ext)
        active = {}
        actions()
        assert(ext_writes == before_writes and mutations == before_mutations and edits == before_edits
            and #queued == 0 and undo_begin == 0 and #errors == 0,
            'Inactive project UI allowed writes, edits or queue operations')
        equal(ext, before_ext, 'Inactive project extstate')
        equal(tracks, original_tracks, 'Inactive project tracks')
        active = project
        frame(0, 0, false)
    end
    if mode == 'picker_cancel' then
        frame(360, 85, true)
    else
        if mode ~= 'saved_guids' then
            click(180, 131) -- Woodwinds is one combined section output.
            assert(rendered_count == 1, 'Woodwinds selected individual instrument outputs')
            click(180, 158) -- Add Flute explicitly.
            assert(rendered_count == 2, 'Flute switch changed parent or sibling selection')
            click(180, 131) -- Section off must preserve the instrument choice.
            assert(rendered_count == 1, 'Disabling Woodwinds changed Flute selection')
            click(180, 131)
            assert(rendered_count == 2, 'Re-enabling Woodwinds changed child selection')
            if mode == 'section_only' then
                click(180, 158)
                assert(rendered_count == 1, 'Section-only render retained a child output')
            end
        else
            frame(0, 0, false)
        end
        if mode == 'picker_switch' then
            attempt_in_other_project(function()
                click(50, 85) -- Continue would persist the selection.
                click(190, 85) -- All would change the desired outputs.
                click(180, 185) -- Oboe would become an extra output.
            end)
        end
        frame(50, 85, true) -- Continue to grid; its first frame is deferred.
        frame(0, 0, false)
        assert(gfx.title:find('Tempo Grid', 1, true), 'Picker did not open grid')
        assert(ext['GPHIL_STEM_LAYERS/selected_guids'] == (mode == 'section_only' and '{6}' or '{6}\n{7}'),
            'Picker did not persist exactly Woodwinds and Flute')
        if mode == 'grid_switch' then
            attempt_in_other_project(function()
                click(40, 25) -- Queue.
                click(550, 25) -- Save.
                click(750, 25) -- Layers.
                click(570, 170); click(570, 170) -- Numeric edit.
            end)
        end
        if mode == 'grid_cancel' then
            frame(430, 25, true)
        else
            -- Set a single non-default tempo so loss of edits on Layers would
            -- cause nine queue passes instead of one.
            click(570, 170); click(570, 170)
            click(670, 170); click(670, 170)
            assert(edits == 2, 'Grid edits were not exercised')
            frame(750, 25, true) -- Reopen Layers without replacing the grid rows.
            assert(gfx.title == 'Stem render layers')
            frame(0, 0, false)
            frame(50, 85, true)
            frame(0, 0, false)
            assert(gfx.title:find('Tempo Grid', 1, true))
            frame(40, 25, true) -- Queue options, then deferred main() reentry.
            assert(#queued == 0, 'Queue started before continuation')
            frame(0, 0, false)
        end
    end
    assert(#deferred == 0, 'Closed action left a running modeless frame')
    assert(picker_labels.Woodwinds and picker_labels.Flutes and picker_labels.Oboes,
        'Orchestral sections or instruments are absent from the picker')
    assert(picker_labels.Band and picker_labels.Saxophones, 'Available Band layers are absent from the picker')
    assert(not picker_labels['Combined stems'] and not picker_labels.Orchestra,
        'Hidden wrapper buses are still displayed in the picker')
    equal(tracks, original_tracks, 'Restored tracks')
    equal(regions, original_regions, 'Restored regions')
    equal(points, original_points, 'Restored tempo map')
    equal(numeric, original_numeric, 'Restored render numbers')
    equal(strings, original_strings, 'Restored render strings')
    if mode == 'picker_cancel' or mode == 'grid_cancel' then
        assert(#queued == 0 and mutations == 0 and undo_begin == 0 and undo_end == 0,
            'Cancel changed selection, mutes, or queued output')
        assert(#errors == 0)
        return
    end
    assert(undo_begin == 1 and undo_end == 1)
    assert(#queued == (mode == 'queue_error' and 1 or 2), 'Grid edits were lost across Layers')
    local click_pass = queued[1]
    assert(click_pass.pattern:find('CLICKDATA', 1, true) and click_pass.bpm == 120)
    for i, track in ipairs(click_pass.tracks) do
        assert(track.selected == (i == 2), 'Click queue selected a stem')
    end
    assert(click_pass.tracks[2].B_MUTE == 0 and click_pass.tracks[3].B_MUTE == 1)
    if mode == 'queue_error' then
        assert(#errors == 1 and errors[1]:find('Injected queue failure', 1, true))
        return
    end
    assert(#errors == 0)
    local stems_pass = queued[2]
    assert(stems_pass.pattern:find('_110_$trackname', 1, true) and stems_pass.bpm == 110)
    for i, track in ipairs(stems_pass.tracks) do
        assert(track.selected == (i == 6 or (i == 7 and mode ~= 'section_only')), 'STEMS queue lost picker selection after CLICK')
    end
    assert(stems_pass.tracks[2].B_MUTE == 1 and stems_pass.tracks[3].B_MUTE == 1)
    for i = 4, (mode == 'section_only' and 6 or 7) do
        assert(stems_pass.tracks[i].B_MUTE == 0, 'Selected layer or ancestor was not unmuted')
    end
    if mode == 'section_only' then
        assert(stems_pass.tracks[7].B_MUTE == 1, 'Section selection changed instrument mute')
    end
    assert(stems_pass.tracks[8].B_MUTE == 1, 'Unrelated muted descendant was unmuted')
    assert(stems_pass.tracks[9].B_MUTE == 1 and stems_pass.tracks[10].B_MUTE == 1,
        'Unselected Band buses were unmuted')
    assert(stems_pass.tracks[11].B_MUTE == 1, 'Unrelated legacy stem bus was unmuted')
end

for _, mode in ipairs({ 'queue', 'section_only', 'picker_cancel', 'grid_cancel', 'queue_error',
    'picker_switch', 'grid_switch', 'saved_guids' }) do run_case(mode) end
print('PASS: picker/grid frames, Layers preserves edits, CLICK/STEMS selections, scoped mute restoration, cancel/error, project guards, saved GUID pruning')
