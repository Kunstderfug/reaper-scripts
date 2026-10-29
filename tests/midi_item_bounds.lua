local bounds = dofile('lib/midi_item_bounds.lua')
local function near(a, b) assert(math.abs(a - b) < 1e-7, a .. ' ~= ' .. b) end
local function fixture()
    local project, other = {}, {}
    local tracks = { { selected = true }, { selected = false } }
    local function item(start, finish, notes, track, selected)
        local it = { start = start, finish = finish, track = track, selected = selected, loop = 1 }
        it.takes = { { events = notes, origin = start, length = finish - start, rate = 1 } }
        return it
    end
    local function note(time, pitch) return { time, string.char(144, pitch or 60, 96), 1 } end
    local items = { item(5, 7, { note(5.2), { 6.8, string.char(128, 60, 0), 0 } }, tracks[1], true),
        item(8, 11.3, { note(8), { 11, string.char(128, 60, 0), 0 } }, tracks[2], false) }
    local undo, refresh, restored, mutations = 0, 0, 0, 0
    local saved = {}
    local function selected(list, predicate)
        local result = {}; for _, value in ipairs(list) do if predicate(value) then result[#result + 1] = value end end
        return result
    end
    local api = {
        EnumProjects = function() return project end,
        CountProjectMarkers = function() return 0 end,
        TimeMap2_timeToQN = function(_, time) return time end,
        TimeMap2_QNToTime = function(_, qn) return qn end,
        TimeMap_QNToMeasures = function(_, qn)
            local bar = math.floor(qn / 4); return bar, bar * 4, (bar + 1) * 4
        end,
        CountMediaItems = function() return #items end,
        GetMediaItem = function(_, i) return items[i + 1] end,
        CountSelectedMediaItems = function() return #selected(items, function(it) return it.selected end) end,
        GetSelectedMediaItem = function(_, i) return selected(items, function(it) return it.selected end)[i + 1] end,
        CountSelectedTracks = function() return #selected(tracks, function(t) return t.selected end) end,
        GetSelectedTrack = function(_, i) return selected(tracks, function(t) return t.selected end)[i + 1] end,
        CountTrackMediaItems = function(t) return #selected(items, function(it) return it.track == t end) end,
        GetTrackMediaItem = function(t, i) return selected(items, function(it) return it.track == t end)[i + 1] end,
        GetActiveTake = function(it) return it.takes[1] end,
        CountTakes = function(it) return #it.takes end,
        GetTake = function(it, i) return it.takes[i + 1] end,
        TakeIsMIDI = function(t) return not t.audio end,
        GetMediaItemTake_Source = function(t) return t end,
        GetMediaSourceFileName = function(t) return t.file or '' end,
        GetMediaSourceLength = function(t) return t.length, true end,
        GetMediaItemTakeInfo_Value = function(t) return t.rate end,
        MIDI_GetProjQNFromPPQPos = function(t) return t.origin end,
        MIDI_GetProjTimeFromPPQPos = function(t, ppq) return ppq / 1000 + (t.shift or 0) end,
        MIDI_GetAllEvts = function(t)
            local result, previous = {}, 0
            for _, e in ipairs(t.events) do
                local ppq = math.floor(e[1] * 1000 + .5)
                result[#result + 1] = string.pack('<i4Bs4', ppq - previous, e[3] or 0, e[2]); previous = ppq
            end
            result[#result + 1] = string.pack('<i4Bs4', 0, 0, string.char(176, 123, 0))
            return true, table.concat(result)
        end,
        GetMediaItemInfo_Value = function(it, key)
            return ({ D_POSITION = it.start, D_LENGTH = it.finish - it.start, C_LOCK = it.lock or 0, B_LOOPSRC = it.loop })[key]
        end,
        GetItemStateChunk = function(it)
            local id = tostring(it)
            saved[id] = { start = it.start, finish = it.finish, loop = it.loop }
            return true, id .. (it.pool and '\nPOOLEDEVTS ' .. it.pool or '')
        end,
        SetItemStateChunk = function(it, chunk)
            local state = saved[chunk:match('[^\n]+')]
            it.start, it.finish, it.loop = state.start, state.finish, state.loop
            for _, t in ipairs(it.takes) do t.shift = nil end
            restored = restored + 1; return true
        end,
        SetMediaItemInfo_Value = function(it, key, value)
            assert(key == 'B_LOOPSRC'); it.loop = value; mutations = mutations + 1; return true
        end,
        MIDI_SetItemExtents = function(it, first, last)
            it.start, it.finish = first, last
            if it.corrupt then it.takes[1].shift = .1 end
            return true
        end,
        Undo_BeginBlock2 = function() undo = undo + 1 end,
        Undo_EndBlock2 = function() undo = undo - 1 end,
        PreventUIRefresh = function(n) refresh = refresh + n end,
        UpdateArrange = function() end,
    }
    return api, project, items, function() return undo, refresh, restored, mutations end, other
end

local api, project, items = fixture()
local left, right = bounds.enclose(api, project, 5.1, 8)
near(left, 4); near(right, 8)
left, right = bounds.enclose(api, project, 4 - 1e-10, 8 + 1e-10)
near(left, 4); near(right, 8)
-- A real varying-meter/tempo mapping is supplied by REAPER, never assumed 4/4.
local meter = {
    TimeMap2_timeToQN = function(_, time) return time / 2 end,
    TimeMap_QNToMeasures = function(_, qn)
        if qn < 3 then return 0, 0, 3 end
        if qn < 6.5 then return 1, 3, 6.5 end
        return 2, 6.5, 11.5
    end,
}
left, right = bounds.enclose(meter, project, 7, 12)
near(left, 3); near(right, 6.5)
assert(#bounds.collect(api, project, 'items') == 1)
assert(#bounds.collect(api, project, 'tracks') == 1)
assert(#bounds.collect(api, project, 'project') == 2)
local plan = bounds.plan(api, project, 'items')
assert(#plan.targets == 1); near(plan.targets[1].left, 4); near(plan.targets[1].right, 8)
assert(bounds.apply(api, project, plan) == 1)
near(items[1].start, 4); near(items[1].finish, 8)
assert(#bounds.plan(api, project, 'items').targets == 0)

-- Beat-one music gets one previous bar; repeated runs do not add more bars.
api, project, items = fixture()
plan = bounds.plan(api, project, 'project')
near(plan.targets[2].left, 4); near(plan.targets[2].right, 12)
bounds.apply(api, project, plan)
assert(#bounds.plan(api, project, 'project').targets == 0)
for _, mode in ipairs({ 'start', 'end' }) do
    api, project, items = fixture()
    plan = bounds.plan(api, project, 'items', mode)
    near(plan.targets[1].left, mode == 'end' and 5 or 4)
    near(plan.targets[1].right, mode == 'start' and 7 or 8)
end
-- Check each edge independently in every mode. An aligned enabled edge must
-- stay put while the other edge is padded; a disabled edge stays untouched.
for _, span in ipairs({ { 4, 7 }, { 5, 8 }, { 4, 8 } }) do
    for _, mode in ipairs({ 'both', 'start', 'end' }) do
        local state
        api, project, items, state = fixture()
        local item = items[1]
        item.start, item.finish = span[1], span[2]
        item.takes[1].origin = item.start
        item.takes[1].length = item.finish - item.start
        local expected_start = mode == 'end' and span[1] or 4
        local expected_end = mode == 'start' and span[2] or 8
        local changed = expected_start ~= span[1] or expected_end ~= span[2]
        plan = bounds.plan(api, project, 'items', mode)
        assert(#plan.targets == (changed and 1 or 0))
        assert(bounds.apply(api, project, plan) == (changed and 1 or 0))
        near(item.start, expected_start); near(item.finish, expected_end)
        assert(#bounds.plan(api, project, 'items', mode).targets == 0)
        local _, _, _, writes = state()
        assert(writes == (changed and 1 or 0))
    end
end
-- Beat-one lead-in is the explicit exception for an aligned start, and still
-- respects End only. Already aligned ends remain unchanged in every mode.
for _, mode in ipairs({ 'both', 'start', 'end' }) do
    api, project, items = fixture()
    local item = items[2]
    items[1].selected, item.selected = false, true
    item.finish, item.takes[1].length = 12, 4
    plan = bounds.plan(api, project, 'items', mode)
    assert(bounds.apply(api, project, plan) == (mode == 'end' and 0 or 1))
    near(item.start, mode == 'end' and 8 or 4); near(item.finish, 12)
    assert(#bounds.plan(api, project, 'items', mode).targets == 0)
end

-- First bar at project time zero cannot have a lead-in before the timeline.
api, project, items = fixture()
items[1].start, items[1].finish = 0, 4
items[1].takes[1].origin, items[1].takes[1].length = 0, 4
items[1].takes[1].events = { { 0, string.char(144, 60, 100) } }
assert(#bounds.plan(api, project, 'items').targets == 0)

local cases = {
    { 'locked item', function(it) it.lock = 1 end },
    { 'repeating MIDI source', function(it) it.takes[1].length = 1 end },
    { 'external MIDI source', function(it) it.takes[1].file = '/tmp/notes.mid' end },
    { 'mixed audio/MIDI takes', function(it) it.takes[2] = { audio = true } end },
    { 'padding would reveal hidden MIDI events', function(it)
        it.takes[1].events[#it.takes[1].events + 1] = { 7, string.char(144, 61, 100) }
    end },
    { 'padding would reveal hidden MIDI events', function(it)
        table.insert(it.takes[1].events, 1, { 4.5, string.char(144, 61, 100) })
    end },
}
for _, case in ipairs(cases) do
    api, project, items = fixture(); case[2](items[1])
    plan = bounds.plan(api, project, 'items')
    assert(#plan.targets == 0 and plan.skipped[case[1]] == 1, case[1])
end
api, project, items = fixture()
items[1].pool, items[2].pool = '{pool}', '{pool}'
assert(bounds.plan(api, project, 'items').skipped['shared pooled MIDI'] == 1)

-- Failure in a later item restores every touched item, with balanced UI/Undo.
local state
api, project, items, state = fixture(); items[2].corrupt = true
plan = bounds.plan(api, project, 'project')
local ok, err = pcall(bounds.apply, api, project, plan)
assert(not ok and err:find('Original items restored.', 1, true))
near(items[1].start, 5); near(items[1].finish, 7)
near(items[2].start, 8); near(items[2].finish, 11.3)
local undo, refresh, restored = state()
assert(undo == 0 and refresh == 0 and restored == 2)
-- Execute the real quick-action entry point: selected items only, no GUI,
-- unchanged second runs and empty selections create no mutation/Undo block.
local original_reaper = reaper
local result_report, deferred
api, project, items, state = fixture()
api.defer = function(callback) deferred = callback end
api.SetExtState = function(section, key, value, persist)
    assert(section == 'GPhil_MIDI_Item_Bounds' and key == 'last_report' and not persist)
    result_report = value
end
api.ShowConsoleMsg = function(message) error('Unexpected console: ' .. message) end
reaper = api
dofile('./GPhil_quantizeMidiItemBounds_selected.lua')
assert(deferred and result_report:find('1 MIDI items aligned.', 1, true))
near(items[1].start, 4); near(items[1].finish, 8)
near(items[2].start, 8); near(items[2].finish, 11.3)
local _, _, _, writes_before = state()
dofile('./GPhil_quantizeMidiItemBounds_selected.lua')
assert(result_report:find('0 MIDI items aligned.', 1, true))
items[1].selected = false
dofile('./GPhil_quantizeMidiItemBounds_selected.lua')
assert(result_report == 'No items selected.')
local _, _, _, writes_after = state()
assert(writes_before == writes_after)
reaper = original_reaper
api, project, items = fixture()
plan = bounds.plan(api, project, { items[2] }, 'both', { lead_in = false })
assert(#plan.targets == 1 and #plan.eligible == 1 and plan.eligible[1] == items[2])
near(plan.targets[1].left, 8); near(plan.targets[1].right, 12)
items[2].lock = 1
assert(#bounds.plan(api, project, { items[2] }, 'both', { lead_in = false }).eligible == 0)
-- Region limits apply to the real planner in every scope and edge mode.
for _, scope in ipairs({ 'items', 'tracks', 'project' }) do
    for _, mode in ipairs({ 'both', 'start', 'end' }) do
        api, project, items = fixture()
        api.CountProjectMarkers = function() return 1 end
        api.EnumProjectMarkers3 = function() return 1, true, 4.5, 7.5 end
        local item = items[1]
        local _, before = api.MIDI_GetAllEvts(item.takes[1], '')
        plan = bounds.plan(api, project, scope, mode)
        assert(bounds.apply(api, project, plan) >= 1)
        near(item.start, mode == 'end' and 5 or 4.5)
        near(item.finish, mode == 'start' and 7 or 7.5)
        local _, after = api.MIDI_GetAllEvts(item.takes[1], '')
        assert(before == after)
        assert(#bounds.plan(api, project, scope, mode).targets == 0)
    end
end

-- Region start overrides beat-one lead-in, and common off-bar ends stay fixed.
api, project, items = fixture()
items[1].start, items[1].finish = 4.2, 11.5
items[1].takes[1].origin, items[1].takes[1].length = 4.2, 7.3
items[2].finish, items[2].takes[1].length = 11.5, 3.5
api.CountProjectMarkers = function() return 1 end
api.EnumProjectMarkers3 = function() return 1, true, 4.1, 11.5 end
plan = bounds.plan(api, project, 'project')
near(plan.targets[1].left, 4.1); near(plan.targets[2].left, 4.1)
near(plan.targets[1].right, 11.5); near(plan.targets[2].right, 11.5)
assert(bounds.apply(api, project, plan) == 2)
assert(#bounds.plan(api, project, 'project').targets == 0)
-- Trim both existing overhangs while preserving source MIDI (including events
-- that become hidden). Disabled edges remain exact, and trim failures roll back.
for _, mode in ipairs({ 'both', 'start', 'end' }) do
    api, project, items = fixture()
    local item = items[1]
    item.start, item.finish, item.loop = 4.4, 11.572, 0
    item.takes[1].origin, item.takes[1].length = 4.4, 7.172
    item.takes[1].events = {
        { 4.45, string.char(144, 60, 100) },
        { 11.55, string.char(128, 60, 0) },
    }
    api.CountProjectMarkers = function() return 1 end
    api.EnumProjectMarkers3 = function() return 1, true, 4.5, 11.5 end
    local _, before = api.MIDI_GetAllEvts(item.takes[1], '')
    plan = bounds.plan(api, project, 'items', mode)
    assert(bounds.apply(api, project, plan) == 1)
    near(item.start, mode == 'end' and 4.4 or 4.5)
    near(item.finish, mode == 'start' and 11.572 or 11.5)
    local _, after = api.MIDI_GetAllEvts(item.takes[1], '')
    assert(before == after and #bounds.plan(api, project, 'items', mode).targets == 0)
end
print('PASS: scopes, varying meter, regions, lead-in, modes, exclusions, rollback, and windowless selected-items action')
