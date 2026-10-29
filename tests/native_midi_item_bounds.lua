-- Run as a ReaScript. Creates and tests a NEW project tab only.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local api = reaper
local bounds = dofile(root .. 'lib/midi_item_bounds.lua')
local report_path = '/tmp/gphil-midi-item-bounds-native.txt'
local report = assert(io.open(report_path, 'w'))
local function log(value) report:write(value .. '\n'); report:flush() end
local function near(a, b) assert(math.abs(a - b) < 1e-7, tostring(a) .. ' ~= ' .. tostring(b)) end
local ok, err = xpcall(function()
    api.Main_OnCommand(40859, 0) -- New project tab; leave existing tabs alone.
    local project = api.EnumProjects(-1, '')
    assert(api.CountTracks(project) == 0, 'Expected a new empty test project.')
    api.SetCurrentBPM(project, 120, false)
    -- Mixed meters and tempo changes exercise real project measure mapping.
    assert(api.SetTempoTimeSigMarker(project, -1, 0, -1, -1, 120, 4, 4, false))
    assert(api.SetTempoTimeSigMarker(project, -1, 8, -1, -1, 90, 3, 4, false))
    assert(api.SetTempoTimeSigMarker(project, -1, 12, -1, -1, 132, 7, 8, false))
    local specs = {
        { 'Piano - uneven edges', { { 1.3, 7.2, 1.6 }, { 9.4, 14.1, 9.7 } } },
        { 'Strings - beat-one lead-in', { { 8, 11.4, 8 }, { 17.2, 20.4, 17.5 } } },
        { 'Winds - varied lengths', { { 4.3, 6.8, 4.6 }, { 23, 27.1, 23.2 } } },
    }
    local colors = { { 186, 145, 64 }, { 68, 166, 180 }, { 156, 101, 183 } }
    local items = {}
    for index, spec in ipairs(specs) do
        api.InsertTrackAtIndex(index - 1, false)
        local track = api.GetTrack(project, index - 1)
        api.GetSetMediaTrackInfo_String(track, 'P_NAME', spec[1], true)
        api.SetMediaTrackInfo_Value(track, 'I_HEIGHTOVERRIDE', 150)
        api.SetMediaTrackInfo_Value(track, 'I_CUSTOMCOLOR', api.ColorToNative(table.unpack(colors[index])) | 0x1000000)
        for j, span in ipairs(spec[2]) do
            local item = api.CreateNewMIDIItemInProj(track, span[1], span[2], true)
            assert(item)
            local take = api.GetActiveTake(item)
            api.GetSetMediaItemTakeInfo_String(take, 'P_NAME', index == 2 and j == 1
                and 'Beat 1: adds one lead-in bar' or ('Uneven MIDI ' .. index .. '.' .. j), true)
            for n = 0, 3 do
                local first = span[3] + n * .5
                local last = math.min(first + .3, span[2] - .1)
                assert(api.MIDI_InsertNote(take, false, false,
                    api.MIDI_GetPPQPosFromProjQN(take, first),
                    api.MIDI_GetPPQPosFromProjQN(take, last), 0, 55 + index * 4 + n, 75 + n * 5, true))
            end
            assert(api.MIDI_InsertCC(take, false, false,
                api.MIDI_GetPPQPosFromProjQN(take, span[3]), 176, 0, 11, 90))
            api.MIDI_Sort(take)
            items[#items + 1] = item
        end
    end
    api.TrackList_AdjustWindows(false)
    api.UpdateArrange()
    api.Undo_OnStateChangeEx2(project, 'Create MIDI item edges test fixture', -1, -1)
    local originals = {}
    for i, item in ipairs(items) do
        local success, chunk = api.GetItemStateChunk(item, '', false); assert(success)
        originals[i] = chunk
    end
    local function reset()
        for i = 1, #originals do items[i] = api.GetMediaItem(project, i - 1) end
        for i, item in ipairs(items) do assert(api.SetItemStateChunk(item, originals[i], false)) end
        api.SelectAllMediaItems(project, false)
        api.SetOnlyTrackSelected(api.GetTrack(project, 0))
        api.SetMediaItemSelected(items[1], true)
        api.Undo_OnStateChangeEx2(project, 'Reset MIDI item edges fixture', -1, -1)
    end
    for _, scope in ipairs({ 'items', 'tracks', 'project' }) do
        for _, mode in ipairs({ 'both', 'start', 'end' }) do
            reset()
            local plan = bounds.plan(api, project, scope, mode)
            log(scope .. '/' .. mode .. ': ' .. bounds.summary(plan))
            local expected = scope == 'items' and 1 or scope == 'tracks' and 2 or 6
            assert(#plan.targets == expected, 'Unexpected eligible item count.')
            if scope == 'project' and mode ~= 'end' then near(plan.targets[3].left, 4) end
            local old = {}
            for i, item in ipairs(items) do
                local pos = api.GetMediaItemInfo_Value(item, 'D_POSITION')
                old[i] = { pos, pos + api.GetMediaItemInfo_Value(item, 'D_LENGTH') }
            end
            assert(bounds.apply(api, project, plan) == expected)
            for i, item in ipairs(items) do
                local pos = api.GetMediaItemInfo_Value(item, 'D_POSITION')
                local finish = pos + api.GetMediaItemInfo_Value(item, 'D_LENGTH')
                if i > expected or mode == 'end' then near(pos, old[i][1]) end
                if i > expected or mode == 'start' then near(finish, old[i][2]) end
            end
            assert(#bounds.plan(api, project, scope, mode).targets == 0, 'Second run grew an item.')
            -- Verify REAPER's actual Undo restores item boundaries.
            api.Undo_DoUndo2(project)
            for i = 1, #items do
                local item = api.GetMediaItem(project, i - 1)
                items[i] = item
                near(api.GetMediaItemInfo_Value(item, 'D_POSITION'), old[i][1])
                near(api.GetMediaItemInfo_Value(item, 'D_LENGTH'), old[i][2] - old[i][1])
            end
            log('PASS: real native extents, MIDI timing, scope, unchanged opposite edge, idempotence, Undo')
        end
    end
    reset()
    -- Leave all tracks selected so the initial UI has a useful track scope.
    api.SelectAllMediaItems(project, false)
    for i = 0, api.CountTracks(project) - 1 do api.SetTrackSelected(api.GetTrack(project, i), true) end
    api.GetSet_LoopTimeRange2(project, true, false, 0, api.TimeMap2_QNToTime(project, 31), false)
    api.Main_OnCommand(40031, 0) -- Zoom to the project.
    local path = root .. 'examples/midi-item-bounds-demo/MIDI Item Bounds Demo.rpp'
    api.RecursiveCreateDirectory(root .. 'examples/midi-item-bounds-demo', 0)
    api.Main_SaveProjectEx(project, path, 8)
    local deployed = api.GetResourcePath() .. '/Scripts/GPhil/GPhil_quantizeMidiItemBounds_gfx.lua'
    local action = api.AddRemoveReaScript(true, 0, deployed, true)
    assert(action > 0, 'Could not register new MIDI item edges action.')
    log('PASS: all nine scope/mode cases. Demo saved: ' .. path)
    api.Main_OnCommand(action, 0)
end, debug.traceback)
if not ok then log('FAIL: ' .. tostring(err)); api.ShowMessageBox(tostring(err), 'MIDI item edges native test', 0) end
report:close()
