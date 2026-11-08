local fades = dofile('lib/region_fades.lua')
-- Captured from the separate native REAPER 7.84 preset probe.
local native_pairs = { [0] = { 0, 0 }, { .5, 0 }, { -.5, 0 }, { 1, 0 },
    { -1, 0 }, { 0, .5 }, { 0, 1 } }
local function near(a, b) assert(math.abs(a - b) < 1e-7, tostring(a) .. ' ~= ' .. tostring(b)) end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for k, v in pairs(value) do result[k] = copy(v) end; return result
end
local function equal(a, b)
    assert(type(a) == type(b))
    if type(a) ~= 'table' then assert(a == b, tostring(a) .. ' ~= ' .. tostring(b)); return end
    for k, v in pairs(b) do equal(a[k], v) end
    for k in pairs(a) do assert(b[k] ~= nil) end
end
local function fixture(modern)
    local state = { project = {}, undo = 0, blocks = 0, refresh = 0, writes = 0, updates = 0, play = 0 }
    state.active = state.project
    -- Compatibility setters can touch modern fields before the authoritative
    -- pair is written. Reading fields directly keeps custom modern states intact.
    local function convert(it, side)
        local prefix = side == 'in' and 'FADEIN' or 'FADEOUT'
        local preset = native_pairs[it['C_' .. prefix .. 'SHAPE']]
        it['D_' .. prefix .. 'DIR_NEW'] = preset[1] + it['D_' .. prefix .. 'DIR'] / 4
        it['D_' .. prefix .. 'DIR2_NEW'] = preset[2]
    end
    local function item(first, last, track)
        local it = { D_POSITION = first, D_LENGTH = last - first, track = track, C_LOCK = 0,
            C_FADEINSHAPE = 1, D_FADEINDIR = 0, C_FADEOUTSHAPE = 3, D_FADEOUTDIR = 0,
            D_FADEINLEN = 1.2, D_FADEOUTLEN = .8, D_FADEINLEN_AUTO = 0, D_FADEOUTLEN_AUTO = .15,
            B_UISEL = 1, D_SNAPOFFSET = .5, take = { D_STARTOFFS = 42, D_PLAYRATE = 2 } }
        convert(it, 'in'); convert(it, 'out'); return it
    end
    -- Track A has ties on both edges; B is a single item; C enters and exits
    -- inside the region. Array ordering deliberately does not match the timeline.
    local items = { item(14, 20, 'A'), item(10, 14, 'A'), item(10, 13, 'A'),
        item(20, 30, 'A'), item(25, 30, 'A'), item(10, 30, 'B'),
        item(12, 18, 'C'), item(18, 22, 'C'), item(22, 28, 'C'),
        item(40, 50, 'A'), item(0, 10, 'A'), item(30, 35, 'A') }
    local regions = {
        { id = 7, first = 10, last = 30, name = 'Edited piece', color = 77, selected = true },
        { id = 9, first = 40, last = 50, name = 'Unselected', color = 99, selected = false },
        { id = 11, first = 10, last = 30, name = 'Same span', color = 11, selected = false },
        { id = 13, first = 60, last = 70, name = 'Empty', color = 13, selected = false },
    }
    local api = {
        EnumProjects = function() return state.active end,
        GetAppVersion = function() return modern and '7.84/macOS-arm64' or '7.80' end,
        GetPlayStateEx = function() return state.play end,
        CountMediaItems = function() return #items end,
        GetMediaItem = function(_, index) return items[index + 1] end,
        GetMediaItemTrack = function(it) return it.track end,
        GetMediaItemInfo_Value = function(it, key) return it[key] or 0 end,
        SetMediaItemInfo_Value = function(it, key, value)
            state.writes = state.writes + 1
            it[key] = value
            if modern then
                if key == 'C_FADEINSHAPE' or key == 'D_FADEINDIR' then convert(it, 'in') end
                if key == 'C_FADEOUTSHAPE' or key == 'D_FADEOUTDIR' then convert(it, 'out') end
            end
            if state.fail_at == state.writes then
                if state.throw then error('Injected setter exception') end
                return false
            end
            return true
        end,
        Undo_BeginBlock2 = function() state.undo = state.undo + 1; state.blocks = state.blocks + 1 end,
        Undo_EndBlock2 = function() state.undo = state.undo - 1 end,
        PreventUIRefresh = function(delta) state.refresh = state.refresh + delta end,
        UpdateArrange = function() state.updates = state.updates + 1 end,
        SetProjectMarker3 = function() error('Fade editing changed a region') end,
        SetMediaItemTakeInfo_Value = function() error('Fade editing changed a take') end,
    }
    return api, state, items, regions
end
local chosen = { [7] = true }
local function clean(state) assert(state.undo == 0 and state.refresh == 0, 'Unbalanced Undo/UI refresh') end
local function untouched(items, before, side)
    local prefix = side == 'in' and 'FADEIN' or 'FADEOUT'
    local ignore = { ['C_' .. prefix .. 'SHAPE'] = true, ['D_' .. prefix .. 'DIR'] = true,
        ['D_' .. prefix .. 'DIR_NEW'] = true, ['D_' .. prefix .. 'DIR2_NEW'] = true }
    local current, original = copy(items), copy(before)
    for _, list in ipairs({ current, original }) do
        for _, it in ipairs(list) do for k in pairs(ignore) do it[k] = nil end end
    end
    equal(current, original)
end

local api, state, items, regions = fixture(false)
local original, bounds = copy(items), copy(regions)
local data = fades.collect(api, state.project, regions, chosen)
assert(data[7] and not data[9] and not data[11])
assert(#data[7].in_items == 4 and #data[7].out_items == 4)
assert(data[7].incoming.shape == 1 and data[7].outgoing.shape == 3)
assert(not data[7].incoming.mixed and not data[7].outgoing.mixed)
local incoming = {}; for _, it in ipairs(data[7].in_items) do incoming[it] = true end
for _, i in ipairs({ 2, 3, 6, 7 }) do assert(incoming[items[i]]) end
equal(items, original); equal(regions, bounds); assert(state.blocks == 0)

-- Current curves distinguish disagreements in shape, old curvature, and the
-- newer continuous parameters even when legacy properties look identical.
items[7].C_FADEINSHAPE = 4
assert(fades.collect(api, state.project, regions, chosen)[7].incoming.mixed)
items[7].C_FADEINSHAPE, items[7].D_FADEINDIR = 1, .2
data = fades.collect(api, state.project, regions, chosen)
assert(data[7].incoming.mixed and data[7].incoming.shape == nil)
api, state, items, regions = fixture(true)
items[7].D_FADEINDIR2_NEW = .37
data = fades.collect(api, state.project, regions, chosen)
assert(data[7].incoming.mixed and data[7].incoming.shape == nil)
data = fades.collect(api, state.project, regions, { [13] = true })
assert(#data[13].in_items == 0 and data[13].incoming.shape == nil and not data[13].incoming.mixed)

-- All seven presets operate independently of extension, source, SWS and fades'
-- durations. Only opening items change; preset changes reset custom curvature.
for _, modern in ipairs({ false, true }) do
    for shape = 0, 6 do
        api, state, items, regions = fixture(modern)
        for _, i in ipairs({ 2, 3, 6, 7 }) do
            items[i].D_FADEINDIR = .3
            if modern then items[i].D_FADEINDIR_NEW, items[i].D_FADEINDIR2_NEW = .37, .19 end
        end
        original, bounds = copy(items), copy(regions)
        local changed, skipped = fades.apply(api, state.project, regions, chosen, nil, 'in', shape)
        assert(changed == 4 and skipped == 0)
        for _, i in ipairs({ 2, 3, 6, 7 }) do
            assert(items[i].C_FADEINSHAPE == shape); near(items[i].D_FADEINDIR, 0)
            if modern then
                near(items[i].D_FADEINDIR_NEW, native_pairs[shape][1])
                near(items[i].D_FADEINDIR2_NEW, native_pairs[shape][2])
            end
        end
        for _, i in ipairs({ 1, 4, 5, 8, 9, 10, 11, 12 }) do equal(items[i], original[i]) end
        untouched(items, original, 'in'); equal(regions, bounds)
        assert(state.blocks == 1 and state.updates == 1); clean(state)
    end
end

-- Fade-out affects the latest endings on each track, including ties, while
-- selecting a single region leaves every other selected region alone.
api, state, items, regions = fixture(true)
original = copy(items)
local changed, skipped = fades.apply(api, state.project, regions, { [7] = true, [9] = true }, 7, 'out', 6)
assert(changed == 4 and skipped == 0)
for _, i in ipairs({ 4, 5, 6, 9 }) do assert(items[i].C_FADEOUTSHAPE == 6) end
for _, i in ipairs({ 1, 2, 3, 7, 8, 10, 11, 12 }) do equal(items[i], original[i]) end
untouched(items, original, 'out'); clean(state)

-- Shared boundary items are changed once, and locked items are reported once.
api, state, items, regions = fixture(false)
items[7].C_LOCK = 1
original = copy(items)
changed, skipped = fades.apply(api, state.project, regions, { [7] = true, [11] = true }, nil, 'in', 5)
assert(changed == 3 and skipped == 1 and state.writes == 6)
equal(items[7], original[7]); clean(state)

-- Empty scopes, unselected row IDs and an already applied legacy preset are inert.
for _, scope in ipairs({ {}, { [13] = true } }) do
    api, state, items, regions = fixture(false)
    changed, skipped = fades.apply(api, state.project, regions, scope, nil, 'in', 5)
    assert(changed == 0 and skipped == 0 and state.blocks == 0)
end
api, state, items, regions = fixture(false)
assert(fades.apply(api, state.project, regions, chosen, 9, 'in', 5) == 0)
assert(fades.apply(api, state.project, regions, chosen, nil, 'in', 1) == 0)
assert(state.blocks == 0 and state.writes == 0)

-- Recollecting at Apply catches a newly earlier item rather than changing the
-- opening items from an earlier preview.
api, state, items, regions = fixture(false)
fades.collect(api, state.project, regions, chosen)
items[1].D_POSITION, items[1].D_LENGTH = 9, 11
changed = fades.apply(api, state.project, regions, chosen, nil, 'in', 5)
assert(changed == 3)
assert(items[1].C_FADEINSHAPE == 5 and items[2].C_FADEINSHAPE == 1 and items[3].C_FADEINSHAPE == 1)

-- A custom modern curve can have unchanged legacy approximation properties;
-- applying a preset still replaces both authoritative modern parameters.
api, state, items, regions = fixture(true)
items[7].D_FADEINDIR_NEW, items[7].D_FADEINDIR2_NEW = .37, -.2
changed = fades.apply(api, state.project, regions, chosen, nil, 'in', 1)
assert(changed == 1)
near(items[7].D_FADEINDIR_NEW, .5); near(items[7].D_FADEINDIR2_NEW, 0)
clean(state)

-- Setter false returns and exceptions restore old and new parameters, even
-- when compatibility setters modify newer fields before they fail.
for _, modern in ipairs({ false, true }) do
    for _, failure in ipairs({ 1, 2, 3 }) do
        api, state, items, regions = fixture(modern)
        items[2].D_FADEINDIR_NEW, items[2].D_FADEINDIR2_NEW = .37, -.2
        original = copy(items)
        state.fail_at, state.throw = failure, failure == 3
        local ok, message = pcall(fades.apply, api, state.project, regions, chosen, nil, 'in', 5)
        assert(not ok and message:find('restored', 1, true), tostring(message))
        equal(items, original)
        assert(state.blocks == 1 and state.updates == 1); clean(state)
    end
end

for _, refusal in ipairs({ 'project', 'recording', 'side', 'shape', 'fractional' }) do
    api, state, items, regions = fixture(false)
    if refusal == 'project' then state.active = {} end
    if refusal == 'recording' then state.play = 5 end
    local side = refusal == 'side' and 'both' or 'in'
    local shape = refusal == 'shape' and 7 or refusal == 'fractional' and 1.5 or 5
    assert(not pcall(fades.apply, api, state.project, regions, chosen, nil, side, shape))
    assert(state.blocks == 0 and state.writes == 0); clean(state)
end
api.GetAppVersion = function() return '7.100/dev' end
assert(fades.modern(api), 'Version minor 100 must not be parsed as decimal .1')

print('region_fades: all tests passed')
