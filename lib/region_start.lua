-- Plan first-per-track trims separately from REAPER mutations and GFX state.
local M = {}
local EPS = 1e-7
local function near(a, b) return math.abs(a - b) < EPS end
local function get(api, item, key) return api.GetMediaItemInfo_Value(item, key) end

function M.regions(api, project)
    local regions = {}
    for i = 0, api.CountProjectMarkers(project) - 1 do
        local found, is_region, first, last, name, id, color = api.EnumProjectMarkers3(project, i)
        assert(found ~= 0, 'Cannot read project regions.')
        if is_region then
            local selected = false
            if api.GetRegionOrMarker and api.GetRegionOrMarkerInfo_Value then
                local handle = api.GetRegionOrMarker(project, i, '')
                if handle then selected = api.GetRegionOrMarkerInfo_Value(project, handle, 'B_UISEL') > .5 end
            end
            regions[#regions + 1] = { id = id, first = first, last = last, name = name,
                color = color, selected = selected }
        end
    end
    table.sort(regions, function(a, b) return a.first == b.first and a.id < b.id or a.first < b.first end)
    return regions
end

local function inspect(api, item, seconds)
    if get(api, item, 'C_LOCK') ~= 0 then return 'opening item is locked' end
    if api.CountTakes(item) == 0 then return 'opening item has no audio take' end
    for i = 0, api.CountTakes(item) - 1 do
        local take = api.GetTake(item, i)
        if not take or api.TakeIsMIDI(take) then return 'opening item contains a MIDI/empty take' end
        -- Native trimming preserves stretch markers, but their nonlinear source
        -- preroll needs a different calculation; never guess at available audio.
        if api.GetTakeNumStretchMarkers(take) > 0 then return 'opening item has stretch markers' end
        local rate = api.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
        local offset = api.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
        if rate <= 0 or offset - seconds * rate < -EPS then
            return 'not enough source audio before an opening take'
        end
    end
end

function M.plan(api, project, regions, chosen, seconds, fade)
    local plan = { rows = {}, targets = {}, item_count = 0, seconds = seconds, fade = fade }
    if not seconds or seconds <= 0 or seconds ~= seconds or seconds == math.huge then
        plan.problem = 'Enter a positive number of seconds.'; return plan
    end
    local items = {}
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local first = get(api, item, 'D_POSITION')
        items[#items + 1] = { item = item, first = first, last = first + get(api, item, 'D_LENGTH'),
            track = api.GetMediaItemTrack(item) }
    end
    local owners = {}
    for _, region in ipairs(regions) do
        local row = { region = region, items = {}, chosen = chosen[region.id] == true }
        local starts = {}
        for _, item in ipairs(items) do
            if item.last > region.first + EPS and item.first < region.last - EPS then
                starts[item.track] = math.min(starts[item.track] or math.huge, item.first)
            end
        end
        for _, item in ipairs(items) do
            if starts[item.track] and near(item.first, starts[item.track])
                and item.last > region.first + EPS and item.first < region.last - EPS then
                row.items[#row.items + 1] = item
                local issue = item.first < region.first - EPS and 'opening item starts before this region'
                    or item.first - seconds < 0 and 'extension would cross project time zero'
                    or inspect(api, item.item, seconds)
                row.issue = row.issue or issue
                if row.chosen then
                    owners[item.item] = owners[item.item] or {}
                    table.insert(owners[item.item], row)
                end
            end
        end
        if #row.items == 0 then row.issue = 'no opening items' end
        if region.first - seconds < 0 then row.issue = 'extension would cross project time zero' end
        plan.rows[#plan.rows + 1] = row
    end
    for _, rows in pairs(owners) do
        if #rows > 1 then
            for _, row in ipairs(rows) do row.issue = 'opening item belongs to multiple checked regions' end
        end
    end
    for _, row in ipairs(plan.rows) do
        if row.chosen and not row.issue then
            plan.targets[#plan.targets + 1] = row
            plan.item_count = plan.item_count + #row.items
        end
    end
    return plan
end

local function set(api, item, key, value)
    assert(api.SetMediaItemInfo_Value(item, key, value), 'Cannot set ' .. key)
end
local fade_keys = { 'D_FADEINLEN', 'D_FADEINLEN_AUTO', 'D_FADEOUTLEN', 'D_FADEOUTLEN_AUTO',
    'D_FADEINDIR', 'D_FADEOUTDIR', 'C_FADEINSHAPE', 'C_FADEOUTSHAPE', 'D_SNAPOFFSET',
    'D_FADEINDIR_NEW', 'D_FADEINDIR2_NEW', 'D_FADEOUTDIR_NEW', 'D_FADEOUTDIR2_NEW' }

function M.apply(api, project, plan)
    assert(api.EnumProjects(-1, '') == project, 'Active project changed. Refresh first.')
    assert(api.BR_SetItemEdges, 'SWS extension is required (BR_SetItemEdges).')
    assert(not plan.problem, plan.problem)
    if #plan.targets == 0 then return 0, 0 end
    assert(api.GetPlayStateEx(project) & 4 == 0, 'Stop recording before extending items.')
    local snapshots = {}
    -- Capture all rollback state before opening an Undo block or editing.
    for _, row in ipairs(plan.targets) do
        for _, entry in ipairs(row.items) do
            assert(near(get(api, entry.item, 'D_POSITION'), entry.first)
                and near(get(api, entry.item, 'D_LENGTH'), entry.last - entry.first), 'Items changed. Refresh first.')
            local ok, chunk = api.GetItemStateChunk(entry.item, '', false)
            assert(ok, 'Cannot back up item. Nothing changed.')
            local fades = {}
            for _, key in ipairs(fade_keys) do fades[key] = get(api, entry.item, key) end
            snapshots[#snapshots + 1] = { entry = entry, chunk = chunk, fades = fades }
        end
    end
    api.Undo_BeginBlock2(project)
    api.PreventUIRefresh(1)
    local ok, err = xpcall(function()
        for _, snapshot in ipairs(snapshots) do
            local entry, fades = snapshot.entry, snapshot.fades
            assert(api.BR_SetItemEdges(entry.item, entry.first - plan.seconds, entry.last), 'Native trim failed.')
            assert(near(get(api, entry.item, 'D_POSITION'), entry.first - plan.seconds)
                and near(get(api, entry.item, 'D_LENGTH'), entry.last - entry.first + plan.seconds),
                'Native trim did not reach the requested edges.')
            for _, key in ipairs(fade_keys) do
                local value = fades[key]
                if key == 'D_SNAPOFFSET' then value = 0
                elseif plan.fade and (key == 'D_FADEINLEN'
                    or key == 'D_FADEINLEN_AUTO' and value > 0) then value = value + plan.seconds end
                set(api, entry.item, key, value)
            end
        end
        for _, row in ipairs(plan.targets) do
            local r = row.region
            assert(api.SetProjectMarker3(project, r.id, true, r.first - plan.seconds,
                r.last, r.name, r.color), 'Cannot extend region ' .. r.id)
        end
    end, debug.traceback)
    local rollback_errors = {}
    if not ok then
        for _, snapshot in ipairs(snapshots) do
            local restored = api.SetItemStateChunk(snapshot.entry.item, snapshot.chunk, false)
            if not restored then rollback_errors[#rollback_errors + 1] = 'item restore failed' end
        end
        for _, row in ipairs(plan.targets) do
            local r = row.region
            if not api.SetProjectMarker3(project, r.id, true, r.first, r.last, r.name, r.color) then
                rollback_errors[#rollback_errors + 1] = 'region ' .. r.id .. ' restore failed'
            end
        end
    end
    api.PreventUIRefresh(-1)
    api.Undo_EndBlock2(project, 'GPhil: extend region starts and opening items', -1)
    api.UpdateArrange()
    if not ok then error(tostring(err) .. (#rollback_errors > 0
        and ('\nRestore incomplete: ' .. table.concat(rollback_errors, ', ') .. '. Use Undo.') or '\nOriginal state restored.')) end
    return #plan.targets, #snapshots
end

function M.report(plan)
    local lines = { plan.problem or string.format('%d regions / %d opening items ready.', #plan.targets, plan.item_count) }
    for _, row in ipairs(plan.rows) do
        if row.chosen and row.issue then
            lines[#lines + 1] = string.format('Skip R%d %s: %s', row.region.id, row.region.name, row.issue)
        end
    end
    return table.concat(lines, '\n')
end

-- Repair region geometry independently of extension eligibility. Locked items,
-- MIDI, and takes without preroll can still supply an exact start to align to.
function M.plan_fix(api, project, regions, chosen)
    local plan = { rows = {}, targets = {} }
    local spans = {}
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local first = get(api, item, 'D_POSITION')
        spans[#spans + 1] = { first = first, last = first + get(api, item, 'D_LENGTH') }
    end
    for _, region in ipairs(regions) do
        local row = { region = region, chosen = chosen[region.id] == true }
        for _, item in ipairs(spans) do
            if item.last > region.first + EPS and item.first < region.last - EPS
                and (not row.first or item.first < row.first) then row.first = item.first end
        end
        if not row.first then row.issue = 'no overlapping media items' end
        plan.rows[#plan.rows + 1] = row
        if row.chosen and row.first and not near(row.first, region.first) then
            plan.targets[#plan.targets + 1] = row
        end
    end
    return plan
end

function M.apply_fix(api, project, plan)
    assert(api.EnumProjects(-1, '') == project, 'Active project changed. Refresh first.')
    if #plan.targets == 0 then return 0 end
    assert(api.GetPlayStateEx(project) & 4 == 0, 'Stop recording before fixing region starts.')
    local current = {}
    for _, region in ipairs(M.regions(api, project)) do current[region.id] = region end
    for _, row in ipairs(plan.targets) do
        local r, now = row.region, current[row.region.id]
        assert(now and near(now.first, r.first) and near(now.last, r.last)
            and now.name == r.name and now.color == r.color, 'Regions changed. Refresh first.')
    end
    api.Undo_BeginBlock2(project)
    api.PreventUIRefresh(1)
    local attempted = {}
    local ok, err = xpcall(function()
        for _, row in ipairs(plan.targets) do
            local r = row.region
            attempted[#attempted + 1] = r
            assert(api.SetProjectMarker3(project, r.id, true, row.first, r.last, r.name, r.color),
                'Cannot fix region ' .. r.id)
        end
    end, debug.traceback)
    local failed = {}
    if not ok then
        for _, r in ipairs(attempted) do
            if not api.SetProjectMarker3(project, r.id, true, r.first, r.last, r.name, r.color) then
                failed[#failed + 1] = tostring(r.id)
            end
        end
    end
    api.PreventUIRefresh(-1)
    api.Undo_EndBlock2(project, 'GPhil: fix selected region starts to first media items', -1)
    api.UpdateArrange()
    if not ok then error(tostring(err) .. (#failed > 0
        and ('\nRestore incomplete for regions ' .. table.concat(failed, ', ') .. '. Use Undo.')
        or '\nOriginal region starts restored.')) end
    return #plan.targets
end

function M.fix_report(plan)
    local lines = { string.format('%d region starts to fix.', #plan.targets) }
    for _, row in ipairs(plan.rows) do
        if row.chosen then
            lines[#lines + 1] = string.format('R%d %s: %s', row.region.id, row.region.name,
                row.issue or near(row.first, row.region.first) and 'already aligned'
                or string.format('%.6f -> %.6f seconds', row.region.first, row.first))
        end
    end
    return table.concat(lines, '\n')
end
return M
