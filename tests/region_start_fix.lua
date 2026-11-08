local model = dofile('lib/region_start.lua')
local function near(actual, expected)
    assert(math.abs(actual - expected) < 1e-7, tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, entry in pairs(value) do result[key] = copy(entry) end
    return result
end
local function equal(actual, expected, path)
    path = path or 'state'
    assert(type(actual) == type(expected), path .. ' changed type')
    if type(actual) ~= 'table' then assert(actual == expected, path .. ' changed'); return end
    for key, value in pairs(expected) do equal(actual[key], value, path .. '.' .. tostring(key)) end
    for key in pairs(actual) do assert(expected[key] ~= nil, path .. ' gained ' .. tostring(key)) end
end
local function fixture()
    local state = { project = {}, play = 0, undo = 0, blocks = 0, refresh = 0,
        writes = 0, updates = 0, labels = {} }
    state.active = state.project
    local regions = {
        { id = 7, first = 10, last = 30, name = 'Excess lead-in', color = 0x1000033, selected = true },
        { id = 9, first = 40, last = 50, name = 'Cut-off beginning', color = 0x1005500, selected = true },
        { id = 11, first = 60, last = 70, name = 'Already aligned', color = 0, selected = true },
        { id = 13, first = 80, last = 90, name = 'Empty piece', color = 0x1000044, selected = true },
        { id = 17, first = 100, last = 110, name = 'Unchecked piece', color = 0, selected = false },
    }
    local function item(first, last, selected)
        return { D_POSITION = first, D_LENGTH = last - first, C_LOCK = 1,
            B_UISEL = selected and 1 or 0, D_FADEINLEN = .75, D_FADEOUTLEN = 1.2,
            D_FADEINLEN_AUTO = -1, D_FADEOUTLEN_AUTO = .25, D_SNAPOFFSET = .4,
            takes = { { midi = true, stretch = 3, D_STARTOFFS = 0, D_PLAYRATE = 2,
                events = { { time = 14, pitch = 60 } } } } }
    end
    -- Unsorted items include exact-touch boundaries that must not count as
    -- overlap, edited pieces, a left-crossing item, and a later unchecked piece.
    local items = { item(18, 22), item(33, 40), item(12, 18, true), item(38, 42),
        item(8, 10), item(60, 65), item(28, 30), item(30, 32), item(50, 55), item(102, 108),
        item(77, 80), item(90, 95) }
    local api = {
        EnumProjects = function() return state.active end,
        GetPlayStateEx = function() return state.play end,
        CountProjectMarkers = function() return #regions + 1 end,
        EnumProjectMarkers3 = function(_, index)
            if index == 0 then return 1, false, 2, 0, 'Ordinary marker', 2, 0 end
            local r = regions[index]
            return r and 1 or 0, true, r and r.first, r and r.last, r and r.name,
                r and r.id, r and r.color
        end,
        GetRegionOrMarker = function(_, index) return regions[index] end,
        GetRegionOrMarkerInfo_Value = function(_, region) return region.selected and 1 or 0 end,
        CountMediaItems = function() return #items end,
        GetMediaItem = function(_, index) return items[index + 1] end,
        GetMediaItemInfo_Value = function(it, key) return it[key] or 0 end,
        SetProjectMarker3 = function(_, id, is_region, first, last, name, color)
            assert(is_region, 'An ordinary marker was changed')
            state.writes = state.writes + 1
            for _, r in ipairs(regions) do
                if r.id == id then
                    -- A failed setter may have partially written its target.
                    r.first, r.last, r.name, r.color = first, last, name, color
                    if state.fail_at == state.writes then return false end
                    return true
                end
            end
            return false
        end,
        Undo_BeginBlock2 = function() state.undo = state.undo + 1; state.blocks = state.blocks + 1 end,
        Undo_EndBlock2 = function(_, label) state.undo = state.undo - 1; state.labels[#state.labels + 1] = label end,
        PreventUIRefresh = function(delta) state.refresh = state.refresh + delta end,
        UpdateArrange = function() state.updates = state.updates + 1 end,
    }
    -- Fixing region bounds must never inspect source suitability or mutate any
    -- item, selection, take, fade, source or envelope state.
    for _, name in ipairs({ 'CountTakes', 'GetTake', 'TakeIsMIDI', 'GetTakeNumStretchMarkers',
        'GetMediaItemTakeInfo_Value', 'SetMediaItemInfo_Value', 'SetMediaItemTakeInfo_Value',
        'SetMediaItemSelected', 'GetItemStateChunk', 'SetItemStateChunk', 'Main_OnCommand' }) do
        api[name] = function() error('Fix region start unexpectedly called ' .. name) end
    end
    local function plan(chosen)
        return model.plan_fix(api, state.project, model.regions(api, state.project),
            chosen or { [7] = true, [9] = true, [11] = true, [13] = true })
    end
    return api, state, items, regions, plan
end
local function clean(state)
    assert(state.undo == 0 and state.refresh == 0, 'Undo/UI refresh block leaked')
end
local function row_for(plan, id)
    for _, row in ipairs(plan.rows) do if row.region.id == id then return row end end
    error('Missing row for region ' .. id)
end

-- Fixing can shorten an excessive lead-in or recover a beginning cut off by
-- the current region. Item selection, locked MIDI and stretch markers are irrelevant.
local api, state, items, regions, plan = fixture()
assert(api.BR_SetItemEdges == nil, 'Fixture should not provide SWS')
local original_items, original_regions = copy(items), copy(regions)
local preview = plan()
assert(#preview.rows == 5 and #preview.targets == 2)
near(row_for(preview, 7).first, 12)
near(row_for(preview, 9).first, 38)
assert(row_for(preview, 11).chosen and not row_for(preview, 11).issue)
assert(row_for(preview, 13).chosen and row_for(preview, 13).issue)
assert(not row_for(preview, 17).chosen)
local report = model.fix_report(preview)
assert(type(report) == 'string' and report:find('Empty piece', 1, true), tostring(report))
equal(items, original_items)
assert(state.writes == 0 and state.blocks == 0, 'Planning mutated the project')
assert(model.apply_fix(api, state.project, preview) == 2)
near(regions[1].first, 12); near(regions[2].first, 38)
for i, r in ipairs(regions) do
    near(r.last, original_regions[i].last)
    assert(r.name == original_regions[i].name and r.color == original_regions[i].color)
    assert(r.selected == original_regions[i].selected, 'Region selection changed')
    if i > 2 then near(r.first, original_regions[i].first) end
end
equal(items, original_items)
assert(state.blocks == 1 and state.writes == 2 and state.updates == 1)
clean(state)

-- Already aligned starts are a no-op and do not create another Undo point.
preview = plan({ [7] = true, [11] = true })
assert(#preview.targets == 0)
assert(model.apply_fix(api, state.project, preview) == 0)
assert(state.blocks == 1 and state.writes == 2); clean(state)

-- No selected regions means no changes even when several would need fixing.
api, state, items, regions, plan = fixture()
preview = plan({})
assert(#preview.targets == 0)
assert(model.apply_fix(api, state.project, preview) == 0)
assert(state.blocks == 0 and state.writes == 0); clean(state)

-- Empty selected regions are skipped; unchecked regions do not acquire targets.
preview = plan({ [13] = true })
assert(#preview.targets == 0 and row_for(preview, 13).issue)
assert(model.apply_fix(api, state.project, preview) == 0)
assert(state.blocks == 0 and state.writes == 0)
preview = plan({ [17] = true })
assert(#preview.targets == 1)
assert(model.apply_fix(api, state.project, preview) == 1)
near(regions[5].first, 102); near(regions[1].first, 10); clean(state)

-- An empty project is inert and still provides a usable report.
api, state, items, regions, plan = fixture()
for i = #items, 1, -1 do items[i] = nil end
preview = plan()
assert(#preview.targets == 0 and #model.fix_report(preview) > 0)
assert(model.apply_fix(api, state.project, preview) == 0)
assert(state.blocks == 0 and state.writes == 0); clean(state)

-- Failure on either marker setter restores every region, including the target
-- whose setter returned false after a partial mutation, within one Undo block.
for _, failed_write in ipairs({ 1, 2 }) do
    api, state, items, regions, plan = fixture()
    original_items, original_regions = copy(items), copy(regions)
    state.fail_at = failed_write
    local ok, message = pcall(model.apply_fix, api, state.project, plan())
    assert(not ok, 'Marker failure was ignored')
    assert(type(message) == 'string' and #message > 0)
    equal(regions, original_regions); equal(items, original_items)
    assert(state.blocks == 1 and state.updates == 1); clean(state)
end

-- Reject stale region snapshots, wrong projects and recording before opening
-- an Undo block or changing any region. Both start and end bounds matter.
for _, refusal in ipairs({ 'project', 'recording', 'first', 'last', 'deleted' }) do
    api, state, items, regions, plan = fixture()
    preview = plan()
    if refusal == 'project' then state.active = {}
    elseif refusal == 'recording' then state.play = 5
    elseif refusal == 'first' then regions[1].first = 11
    elseif refusal == 'last' then regions[2].last = 51
    elseif refusal == 'deleted' then table.remove(regions, 1) end
    original_regions, original_items = copy(regions), copy(items)
    assert(not pcall(model.apply_fix, api, state.project, preview), refusal .. ' was not refused')
    equal(regions, original_regions); equal(items, original_items)
    assert(state.blocks == 0 and state.writes == 0); clean(state)
end

print('region_start_fix: all tests passed')
