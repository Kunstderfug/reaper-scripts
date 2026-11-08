local model = dofile('lib/region_start.lua')
local function near(actual, expected)
    assert(math.abs(actual - expected) < 1e-7, tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end
local function fixture()
    local state = { project = {}, undo = 0, refresh = 0, blocks = 0, trims = 0, restores = 0,
        updates = 0, play = 0, region_writes = 0 }
    state.active = state.project
    local tracks = { {}, {}, {} }
    local function item(first, last, track)
        return { track = track, D_POSITION = first, D_LENGTH = last - first, C_LOCK = 0,
            D_FADEINLEN = .2, D_FADEINLEN_AUTO = -1, D_FADEOUTLEN = .3,
            D_FADEOUTLEN_AUTO = .15, D_FADEINDIR = .25, D_FADEOUTDIR = -.2,
            C_FADEINSHAPE = 3, C_FADEOUTSHAPE = 4, D_SNAPOFFSET = .5,
            takes = { { D_STARTOFFS = 5, D_PLAYRATE = 1 } } }
    end
    -- Deliberately unsorted, with several edits per track and an unrelated region.
    local items = { item(18, 30, tracks[1]), item(10, 14, tracks[2]),
        item(10, 13, tracks[1]), item(13, 18, tracks[1]),
        item(14, 30, tracks[2]), item(10, 30, tracks[3]), item(40, 50, tracks[1]) }
    local regions = {
        { id = 7, first = 10, last = 30, name = 'Edited piece', color = 0x1000033, selected = true },
        { id = 9, first = 40, last = 50, name = 'Other piece', color = 0x1005500, selected = false },
    }
    local saved = {}
    local api = {
        EnumProjects = function() return state.active end,
        GetPlayStateEx = function() return state.play end,
        CountProjectMarkers = function() return #regions + 1 end,
        EnumProjectMarkers3 = function(_, index)
            if index == 0 then return 1, false, 2, 0, 'Marker', 2, 0 end
            local r = regions[index]
            return r and 1 or 0, true, r and r.first, r and r.last, r and r.name,
                r and r.id, r and r.color
        end,
        GetRegionOrMarker = function(_, index) return index > 0 and regions[index] or nil end,
        GetRegionOrMarkerInfo_Value = function(_, region) return region.selected and 1 or 0 end,
        CountMediaItems = function() return #items end,
        GetMediaItem = function(_, index) return items[index + 1] end,
        GetMediaItemTrack = function(it) return it.track end,
        GetMediaItemInfo_Value = function(it, key) return it[key] or 0 end,
        SetMediaItemInfo_Value = function(it, key, value)
            if state.fail_property == key then return false end
            it[key] = value; return true
        end,
        CountTakes = function(it) return #it.takes end,
        GetTake = function(it, index) return it.takes[index + 1] end,
        TakeIsMIDI = function(take) return take.midi or false end,
        GetTakeNumStretchMarkers = function(take) return take.stretch or 0 end,
        GetMediaItemTakeInfo_Value = function(take, key) return take[key] end,
        GetItemStateChunk = function(it)
            if state.fail_backup then return false, '' end
            local key = tostring(it); saved[key] = copy(it); return true, key
        end,
        SetItemStateChunk = function(it, key)
            local track = it.track
            for field in pairs(it) do it[field] = nil end
            for field, value in pairs(copy(saved[key])) do it[field] = value end
            it.track = track
            state.restores = state.restores + 1; return true
        end,
        BR_SetItemEdges = function(it, first, last)
            state.trims = state.trims + 1
            if state.block_trim == state.trims then return true end
            local delta = it.D_POSITION - first
            it.D_POSITION, it.D_LENGTH = first, last - first
            for _, take in ipairs(it.takes) do
                take.D_STARTOFFS = take.D_STARTOFFS - delta * take.D_PLAYRATE
            end
            -- Native edge actions can adjust fades and snap offsets. The model
            -- must restore their intended values rather than trust these results.
            it.D_FADEINLEN, it.D_FADEOUTLEN = 99, 98
            it.D_FADEINLEN_AUTO, it.D_FADEOUTLEN_AUTO, it.D_SNAPOFFSET = 97, 96, 95
            if state.fail_trim == state.trims then return false end
            return true
        end,
        SetProjectMarker3 = function(_, id, is_region, first, last, name, color)
            assert(is_region)
            state.region_writes = state.region_writes + 1
            if state.fail_region == state.region_writes then return false end
            for _, r in ipairs(regions) do
                if r.id == id then
                    r.first, r.last, r.name, r.color = first, last, name, color
                    return true
                end
            end
            return false
        end,
        Undo_BeginBlock2 = function() state.undo = state.undo + 1; state.blocks = state.blocks + 1 end,
        Undo_EndBlock2 = function() state.undo = state.undo - 1 end,
        PreventUIRefresh = function(delta) state.refresh = state.refresh + delta end,
        UpdateArrange = function() state.updates = state.updates + 1 end,
    }
    local function plan(seconds, fade, chosen)
        return model.plan(api, state.project, model.regions(api, state.project),
            chosen or { [7] = true }, seconds or 1, fade == nil and true or fade)
    end
    return api, state, items, regions, plan
end
local function clean(state)
    assert(state.undo == 0 and state.refresh == 0, 'Undo/UI refresh block leaked')
end

-- Only each track's first item changes; internal edits, later regions and all
-- current media positions remain stable, including non-unit-rate inactive takes.
local api, state, items, regions, plan = fixture()
items[3].takes[2] = { D_STARTOFFS = 8, D_PLAYRATE = 2 }
local before = copy(items)
local listed = model.regions(api, state.project)
assert(#listed == 2 and listed[1].id == 7 and listed[1].selected and not listed[2].selected)
local preview = plan(1, true)
assert(#preview.targets == 1 and preview.item_count == 3)
local changed_regions, changed_items = model.apply(api, state.project, preview)
assert(changed_regions == 1 and changed_items == 3 and state.blocks == 1)
for _, index in ipairs({ 2, 3, 6 }) do
    local it, original = items[index], before[index]
    near(it.D_POSITION, 9)
    near(it.D_POSITION + it.D_LENGTH, original.D_POSITION + original.D_LENGTH)
    for take_index, take in ipairs(it.takes) do
        local old = original.takes[take_index]
        near(take.D_PLAYRATE, old.D_PLAYRATE)
        -- At the original timeline start, playback still addresses the same source sample.
        near(take.D_STARTOFFS + (original.D_POSITION - it.D_POSITION) * take.D_PLAYRATE, old.D_STARTOFFS)
    end
    near(it.D_FADEINLEN, 1.2); near(it.D_FADEINLEN_AUTO, -1)
    near(it.D_SNAPOFFSET, 0)
    for _, field in ipairs({ 'D_FADEOUTLEN', 'D_FADEOUTLEN_AUTO', 'D_FADEINDIR',
        'D_FADEOUTDIR', 'C_FADEINSHAPE', 'C_FADEOUTSHAPE' }) do near(it[field], original[field]) end
end
for _, index in ipairs({ 1, 4, 5, 7 }) do
    near(items[index].D_POSITION, before[index].D_POSITION)
    near(items[index].D_LENGTH, before[index].D_LENGTH)
    near(items[index].takes[1].D_STARTOFFS, before[index].takes[1].D_STARTOFFS)
    near(items[index].D_FADEINLEN, before[index].D_FADEINLEN)
end
near(regions[1].first, 9); near(regions[1].last, 30)
assert(regions[1].name == 'Edited piece' and regions[1].color == 0x1000033)
near(regions[2].first, 40); clean(state)

-- Fractional extensions support enabled automatic fades and optional edge-only mode.
for _, fade in ipairs({ true, false }) do
    api, state, items, regions, plan = fixture()
    items[2].D_FADEINLEN_AUTO = .4
    model.apply(api, state.project, plan(.75, fade))
    near(items[2].D_FADEINLEN_AUTO, fade and 1.15 or .4)
    near(items[2].D_FADEINLEN, fade and .95 or .2)
    near(items[2].D_SNAPOFFSET, 0)
    near(items[2].D_FADEOUTLEN_AUTO, .15)
    near(regions[1].first, 9.25); clean(state)
end

-- An unsafe opening take skips the whole region, including otherwise valid tracks.
local unsafe = {
    { 'source audio', function(it) it.takes[2] = { D_STARTOFFS = 1, D_PLAYRATE = 2 } end },
    { 'locked', function(it) it.C_LOCK = 1 end },
    { 'MIDI', function(it) it.takes[2] = { midi = true, D_STARTOFFS = 8, D_PLAYRATE = 1 } end },
    { 'stretch markers', function(it) it.takes[1].stretch = 2 end },
    { 'no audio take', function(it) it.takes = {} end },
    { 'source audio', function(it) it.takes[1].D_PLAYRATE = 0 end },
    { 'before this region', function(it) it.D_POSITION = 9 end },
}
for _, case in ipairs(unsafe) do
    api, state, items, regions, plan = fixture()
    case[2](items[2])
    preview = plan()
    assert(#preview.targets == 0 and preview.item_count == 0)
    assert(model.report(preview):find(case[1], 1, true), model.report(preview))
    local count = model.apply(api, state.project, preview)
    assert(count == 0 and state.blocks == 0 and state.trims == 0)
    near(regions[1].first, 10); clean(state)
end

-- Project-zero checks cover region lead-in even if opening media starts later.
api, state, items, regions, plan = fixture()
regions[1].first = .5
assert(#plan().targets == 0 and model.report(plan()):find('time zero', 1, true))

-- Shared opening items cannot be extended twice by overlapping checked regions.
api, state, items, regions, plan = fixture()
regions[3] = { id = 11, first = 10, last = 25, name = 'Nested', color = 0 }
preview = plan(1, true, { [7] = true, [11] = true })
assert(#preview.targets == 0 and model.report(preview):find('multiple checked regions', 1, true))
preview = plan(1, true, { [7] = true })
assert(#preview.targets == 1 and preview.item_count == 3)

-- Unchecked regions do not mutate, and the scope can target a later piece alone.
api, state, items, regions, plan = fixture()
preview = plan(1, true, {})
assert(#preview.targets == 0 and model.apply(api, state.project, preview) == 0)
preview = plan(1, true, { [9] = true })
assert(#preview.targets == 1 and preview.item_count == 1)
model.apply(api, state.project, preview)
near(items[7].D_POSITION, 39); near(items[2].D_POSITION, 10)
near(regions[1].first, 10); near(regions[2].first, 39); clean(state)

-- Every rejected input is inert, including nonfinite numbers.
for _, seconds in ipairs({ 0, -1, math.huge, -math.huge, 0 / 0 }) do
    api, state, items, regions, plan = fixture()
    preview = model.plan(api, state.project, model.regions(api, state.project), { [7] = true }, seconds, true)
    assert(preview.problem and #preview.targets == 0)
    assert(not pcall(model.apply, api, state.project, preview))
    assert(state.blocks == 0 and state.trims == 0); clean(state)
end

-- Native false returns, blocked actions and later region write failures all
-- restore media, all take offsets, fades and regions in the same Undo block.
for _, failure in ipairs({ 'fail_trim', 'block_trim', 'fail_region', 'fail_property' }) do
    api, state, items, regions, plan = fixture()
    items[3].takes[2] = { D_STARTOFFS = 8, D_PLAYRATE = 2 }
    state[failure] = failure == 'fail_property' and 'D_FADEINLEN' or 2
    preview = plan(1, true, { [7] = true, [9] = true })
    local ok, message = pcall(model.apply, api, state.project, preview)
    assert(not ok and message:find('Original state restored', 1, true), tostring(message))
    near(items[2].D_POSITION, 10); near(items[3].D_LENGTH, 3)
    near(items[3].takes[1].D_STARTOFFS, 5); near(items[3].takes[2].D_STARTOFFS, 8)
    near(items[2].D_FADEINLEN, .2); near(items[2].D_FADEOUTLEN, .3)
    near(items[2].D_SNAPOFFSET, .5)
    near(regions[1].first, 10); near(regions[2].first, 40)
    assert(state.restores == 4 and state.blocks == 1 and state.updates == 1); clean(state)
end

-- Refusals before mutation must not create an Undo point or touch the project.
for _, refusal in ipairs({ 'project', 'recording', 'backup', 'stale', 'missing_sws' }) do
    api, state, items, regions, plan = fixture()
    preview = plan()
    if refusal == 'project' then state.active = {}
    elseif refusal == 'recording' then state.play = 5
    elseif refusal == 'backup' then state.fail_backup = true
    elseif refusal == 'stale' then items[2].D_LENGTH = 5
    elseif refusal == 'missing_sws' then api.BR_SetItemEdges = nil end
    assert(not pcall(model.apply, api, state.project, preview), refusal .. ' was not refused')
    assert(state.blocks == 0 and state.trims == 0 and state.region_writes == 0)
    near(regions[1].first, 10); clean(state)
end

print('region_start: all tests passed')
