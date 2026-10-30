local snap = dofile('lib/region_snap.lua')
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, entry in pairs(value) do result[key] = copy(entry) end; return result
end
local function equal(actual, expected)
    assert(type(actual) == type(expected))
    if type(actual) ~= 'table' then assert(actual == expected, tostring(actual) .. ' ~= ' .. tostring(expected)); return end
    for key, value in pairs(expected) do equal(actual[key], value) end
    for key in pairs(actual) do assert(expected[key] ~= nil) end
end
local function fixture()
    local state = { project = {}, blocks = 0, undo = 0, refresh = 0, writes = 0, updates = 0, play = 0 }
    state.active = state.project
    local function item(first, last, track, offset)
        return { D_POSITION = first, D_LENGTH = last - first, track = track, D_SNAPOFFSET = offset,
            C_LOCK = 0, B_UISEL = 1, D_FADEINLEN = 1.2, D_FADEOUTLEN = .8,
            C_FADEINSHAPE = 3, C_FADEOUTSHAPE = 5, D_FADEINDIR = .3, D_FADEOUTDIR = -.5,
            take = { D_STARTOFFS = 42, D_PLAYRATE = 2 } }
    end
    local items = { item(14, 30, 'A', .8), item(10, 14, 'A', .5), item(10, 20, 'B', 0),
        item(20, 30, 'B', 1.2), item(10, 13, 'A', -.3), item(40, 50, 'A', 2), item(0, 10, 'A', 4) }
    local regions = {
        { id = 7, first = 10, last = 30, name = 'Selected', color = 7, selected = true },
        { id = 9, first = 40, last = 50, name = 'Unselected', color = 9, selected = false },
        { id = 11, first = 10, last = 30, name = 'Same span', color = 11, selected = false },
        { id = 13, first = 60, last = 70, name = 'Empty', color = 13, selected = false },
    }
    local api = {
        EnumProjects = function() return state.active end,
        GetPlayStateEx = function() return state.play end,
        CountMediaItems = function() return #items end,
        GetMediaItem = function(_, index) return items[index + 1] end,
        GetMediaItemTrack = function(it) return it.track end,
        GetMediaItemInfo_Value = function(it, key) return it[key] or 0 end,
        SetMediaItemInfo_Value = function(it, key, value)
            assert(key == 'D_SNAPOFFSET', 'Snap reset changed ' .. key)
            state.writes = state.writes + 1; it[key] = value
            if state.fail_at == state.writes then
                if state.throw then error('Injected setter failure') end
                return false
            end
            return true
        end,
        SetProjectMarker3 = function() error('Snap reset changed region bounds') end,
        Undo_BeginBlock2 = function() state.blocks = state.blocks + 1; state.undo = state.undo + 1 end,
        Undo_EndBlock2 = function() state.undo = state.undo - 1 end,
        PreventUIRefresh = function(delta) state.refresh = state.refresh + delta end,
        UpdateArrange = function() state.updates = state.updates + 1 end,
    }
    return api, state, items, regions
end
local chosen = { [7] = true }
local function clean(state) assert(state.undo == 0 and state.refresh == 0, 'Undo/UI refresh leaked') end

-- Earliest items on each track are the only candidates, including tied starts.
-- The third opening item already has zero offset and needs no mutation.
local api, state, items, regions = fixture()
local original, bounds = copy(items), copy(regions)
local plan = snap.plan(api, state.project, regions, chosen)
assert(#plan.targets == 2 and plan.skipped == 0)
local targets = {}; for _, target in ipairs(plan.targets) do targets[target.item] = target.offset end
assert(targets[items[2]] == .5 and targets[items[5]] == -.3)
assert(not targets[items[1]] and not targets[items[4]] and not targets[items[6]])
equal(items, original); assert(state.writes == 0 and state.blocks == 0)
assert(api.BR_SetItemEdges == nil, 'Snap reset must work without SWS')
local changed, skipped = snap.apply(api, state.project, regions, chosen)
assert(changed == 2 and skipped == 0 and state.blocks == 1 and state.writes == 2)
original[2].D_SNAPOFFSET, original[5].D_SNAPOFFSET = 0, 0
equal(items, original); equal(regions, bounds)
assert(state.updates == 1); clean(state)

-- Repeating reset is inert and adds no Undo point.
assert(snap.apply(api, state.project, regions, chosen) == 0)
assert(state.blocks == 1 and state.writes == 2); clean(state)

-- Shared selected regions deduplicate opening items, including locked skips.
api, state, items, regions = fixture()
items[2].C_LOCK = 1
plan = snap.plan(api, state.project, regions, { [7] = true, [11] = true })
assert(#plan.targets == 1 and plan.skipped == 1)
changed, skipped = snap.apply(api, state.project, regions, { [7] = true, [11] = true })
assert(changed == 1 and skipped == 1 and state.writes == 1)
assert(items[2].D_SNAPOFFSET == .5 and items[5].D_SNAPOFFSET == 0); clean(state)

-- No selection or no overlapping items must never fall back to the whole project.
for _, scope in ipairs({ {}, { [13] = true } }) do
    api, state, items, regions = fixture()
    plan = snap.plan(api, state.project, regions, scope)
    assert(#plan.targets == 0 and plan.skipped == 0)
    changed, skipped = snap.apply(api, state.project, regions, scope)
    assert(changed == 0 and skipped == 0 and state.blocks == 0 and state.writes == 0)
    clean(state)
end

-- Applying after media changed must recollect the opening boundary rather than
-- reset offsets of the old preview's opening items.
api, state, items, regions = fixture()
snap.plan(api, state.project, regions, chosen)
items[1].D_POSITION, items[1].D_LENGTH = 9, 21
changed = snap.apply(api, state.project, regions, chosen)
assert(changed == 1 and items[1].D_SNAPOFFSET == 0)
assert(items[2].D_SNAPOFFSET == .5 and items[5].D_SNAPOFFSET == -.3); clean(state)

-- A setter may fail after changing its item. Restore both the previous item and
-- failed item and close the same Undo/UI refresh block on false or exceptions.
for _, failure in ipairs({ 1, 2, 3 }) do
    api, state, items, regions = fixture()
    original, bounds = copy(items), copy(regions)
    state.fail_at, state.throw = failure == 3 and 2 or failure, failure == 3
    local ok, message = pcall(snap.apply, api, state.project, regions, chosen)
    assert(not ok and type(message) == 'string' and #message > 0)
    equal(items, original); equal(regions, bounds)
    assert(state.blocks == 1 and state.updates == 1); clean(state)
end

for _, refusal in ipairs({ 'project', 'recording' }) do
    api, state, items, regions = fixture()
    original = copy(items)
    if refusal == 'project' then state.active = {} else state.play = 5 end
    assert(not pcall(snap.apply, api, state.project, regions, chosen))
    equal(items, original)
    assert(state.blocks == 0 and state.writes == 0); clean(state)
end

print('region_snap: all tests passed')
