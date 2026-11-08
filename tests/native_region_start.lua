-- Run in the current REAPER app. Creates/closes a temporary project tab only.
if not reaper then print('native_region_start: skipped outside REAPER'); return end
local api = reaper
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local edges = dofile(root .. 'lib/region_start.lua')
local log = assert(io.open('/tmp/gphil-region-start-native.txt', 'w'))
local original_project, test_project = api.EnumProjects(-1, ''), nil
local function near(a, b) assert(math.abs(a - b) < 1e-7, tostring(a) .. ' ~= ' .. tostring(b)) end
local function get(item, key) return api.GetMediaItemInfo_Value(item, key) end
local function set(item, key, value) assert(api.SetMediaItemInfo_Value(item, key, value)) end
local ok, err = xpcall(function()
    assert(api.BR_SetItemEdges, 'SWS not loaded')
    api.Main_OnCommand(40859, 0) -- New project tab in the current application.
    local project = api.EnumProjects(-1, '')
    assert(project ~= original_project, 'Test tab was not created.')
    test_project = project
    assert(api.CountTracks(project) == 0)
    local items = {}
    for track_index = 0, 2 do
        api.InsertTrackAtIndex(track_index, false)
        local track = api.GetTrack(project, track_index)
        for edit = 0, 2 do
            local item = api.AddMediaItemToTrack(track)
            local take = api.AddTakeToMediaItem(item)
            local source = api.PCM_Source_CreateFromFile(root .. 'examples/tempo-set-demo/Media/demo.wav')
            assert(source); api.SetMediaItemTake_Source(take, source)
            assert(api.SetMediaItemTakeInfo_Value(take, 'D_STARTOFFS', 2 + edit))
            set(item, 'D_POSITION', 10 + edit * 2)
            set(item, 'D_LENGTH', 2)
            set(item, 'D_FADEINLEN', .2)
            set(item, 'D_FADEINLEN_AUTO', -1)
            set(item, 'D_FADEOUTLEN', .3)
            set(item, 'D_SNAPOFFSET', .4)
            items[#items + 1] = item
        end
    end
    -- An unchecked piece must never change.
    local first_id = api.AddProjectMarker2(project, true, 10, 16, 'Selected piece', -1, 0)
    local other_id = api.AddProjectMarker2(project, true, 22, 26, 'Unselected piece', -1, 0)
    local function select(id, value)
        for index = 0, api.CountProjectMarkers(project) - 1 do
            local marker = api.GetRegionOrMarker(project, index, '')
            if api.GetRegionOrMarkerInfo_Value(project, marker, 'I_NUMBER') == id then
                assert(api.SetRegionOrMarkerInfo_Value(project, marker, 'B_UISEL', value)); return
            end
        end
        error('Region not found')
    end
    select(first_id, 1); select(other_id, 0)
    local regions = edges.regions(api, project)
    local chosen = {}; for _, r in ipairs(regions) do chosen[r.id] = r.selected end
    assert(chosen[first_id] and not chosen[other_id], 'Native B_UISEL selection not read correctly')
    local plan = edges.plan(api, project, regions, chosen, 1, true)
    assert(#plan.targets == 1 and plan.item_count == 3, edges.report(plan))
    local original = {}
    for i, item in ipairs(items) do
        local yes, chunk = api.GetItemStateChunk(item, '', false); assert(yes); original[i] = chunk
    end
    local regions_done, items_done = edges.apply(api, project, plan)
    assert(regions_done == 1 and items_done == 3)
    for i, item in ipairs(items) do
        local edit = (i - 1) % 3
        near(get(item, 'D_POSITION'), edit == 0 and 9 or 10 + edit * 2)
        near(get(item, 'D_LENGTH'), edit == 0 and 3 or 2)
        near(get(item, 'D_FADEINLEN'), edit == 0 and 1.2 or .2)
        near(get(item, 'D_FADEINLEN_AUTO'), -1)
        near(get(item, 'D_FADEOUTLEN'), .3)
        near(get(item, 'D_SNAPOFFSET'), edit == 0 and 0 or .4)
        local take = api.GetActiveTake(item)
        near(api.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'), edit == 0 and 1 or 2 + edit)
    end
    regions = edges.regions(api, project)
    for _, r in ipairs(regions) do
        near(r.first, r.id == first_id and 9 or 22)
        near(r.last, r.id == first_id and 16 or 26)
    end
    log:write('PASS: native selected-region lookup, three first-per-track trims, unchanged internal edits, media offsets, fades, snap anchors, region ends\n')
    api.Undo_DoUndo2(project)
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local edit = i % 3
        near(get(item, 'D_POSITION'), 10 + edit * 2)
        near(get(item, 'D_LENGTH'), 2)
        near(get(item, 'D_FADEINLEN'), .2)
    end
    for _, r in ipairs(edges.regions(api, project)) do near(r.first, r.id == first_id and 10 or 22) end
    log:write('PASS: single native Undo restores opening items and region\n')
end, debug.traceback)
log:write(ok and 'PASS: all native checks\n' or 'FAIL: ' .. tostring(err) .. '\n'); log:close()
-- Discard the generated test tab; never close the app or the original project.
if test_project and api.EnumProjects(-1, '') == test_project then
    api.GetSetProjectInfo(test_project, 'DIRTY', 0, true)
    api.Main_OnCommand(40860, 0) -- Close current project tab.
end
api.SelectProjectInstance(original_project)
