-- Read and change only the outer fades of each selected region's tracks.
local M = {}
local EPS = 1e-7
local function near(a, b) return math.abs(a - b) < EPS end
local function get(api, item, key) return api.GetMediaItemInfo_Value(item, key) end
local fields = {
    ['in'] = { 'C_FADEINSHAPE', 'D_FADEINDIR', 'D_FADEINDIR_NEW', 'D_FADEINDIR2_NEW' },
    out = { 'C_FADEOUTSHAPE', 'D_FADEOUTDIR', 'D_FADEOUTDIR_NEW', 'D_FADEOUTDIR2_NEW' },
}
-- Standard presets verified against REAPER 7.84's native compatibility setters.
M.presets = {
    [0] = { dir_new = 0, dir2_new = 0 },
    [1] = { dir_new = .5, dir2_new = 0 },
    [2] = { dir_new = -.5, dir2_new = 0 },
    [3] = { dir_new = 1, dir2_new = 0 },
    [4] = { dir_new = -1, dir2_new = 0 },
    [5] = { dir_new = 0, dir2_new = .5 },
    [6] = { dir_new = 0, dir2_new = 1 },
}

-- REAPER 7.81 replaced the legacy shape/curvature with two continuous parameters.
function M.modern(api)
    if not api.GetAppVersion then return false end
    local major, minor = api.GetAppVersion():match('^(%d+)%.(%d+)')
    return major and (tonumber(major) > 7 or tonumber(major) == 7 and tonumber(minor) >= 81) or false
end

local function read(api, item, side, modern)
    local keys = fields[side]
    local value = { shape = get(api, item, keys[1]), dir = get(api, item, keys[2]),
        dir_new = 0, dir2_new = 0, mixed = false }
    value.custom = not near(value.dir, 0)
    if modern then
        value.dir_new, value.dir2_new = get(api, item, keys[3]), get(api, item, keys[4])
        value.legacy_shape, value.shape = value.shape, nil
        for shape, preset in pairs(M.presets) do
            if near(value.dir_new, preset.dir_new) and near(value.dir2_new, preset.dir2_new) then
                value.shape = shape; break
            end
        end
        value.custom = value.shape == nil
    end
    return value
end

local function summarize(api, items, side, modern)
    local summary
    for _, item in ipairs(items) do
        local value = read(api, item, side, modern)
        if not summary then summary = value
        elseif modern and (not near(summary.dir_new, value.dir_new) or not near(summary.dir2_new, value.dir2_new))
            or not modern and (summary.shape ~= value.shape or not near(summary.dir, value.dir)) then
            summary.mixed = true
        end
    end
    summary = summary or { shape = nil, dir = 0, dir_new = 0, dir2_new = 0, mixed = false, custom = false }
    if summary.mixed then summary.shape = nil end
    return summary
end

function M.collect(api, project, regions, chosen)
    local spans, result, modern = {}, {}, M.modern(api)
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local first = get(api, item, 'D_POSITION')
        spans[#spans + 1] = { item = item, first = first,
            last = first + get(api, item, 'D_LENGTH'), track = api.GetMediaItemTrack(item) }
    end
    for _, region in ipairs(regions) do
        if chosen[region.id] then
            local row, tracks = { in_items = {}, out_items = {} }, {}
            for _, item in ipairs(spans) do
                if item.last > region.first + EPS and item.first < region.last - EPS then
                    local ends = tracks[item.track] or { first = math.huge, last = -math.huge }
                    ends.first, ends.last = math.min(ends.first, item.first), math.max(ends.last, item.last)
                    tracks[item.track] = ends
                end
            end
            for _, item in ipairs(spans) do
                local ends = tracks[item.track]
                if ends and item.last > region.first + EPS and item.first < region.last - EPS then
                    if near(item.first, ends.first) then row.in_items[#row.in_items + 1] = item.item end
                    if near(item.last, ends.last) then row.out_items[#row.out_items + 1] = item.item end
                end
            end
            row.incoming = summarize(api, row.in_items, 'in', modern)
            row.outgoing = summarize(api, row.out_items, 'out', modern)
            result[region.id] = row
        end
    end
    return result
end

function M.apply(api, project, regions, chosen, region_id, side, shape)
    assert(api.EnumProjects(-1, '') == project, 'Active project changed. Refresh first.')
    assert(fields[side], 'Choose fade-in or fade-out.')
    assert(type(shape) == 'number' and shape == math.floor(shape) and shape >= 0 and shape <= 6,
        'Choose a native fade shape from 0 to 6.')
    assert(api.GetPlayStateEx(project) & 4 == 0, 'Stop recording before changing fades.')
    local modern, keys = M.modern(api), fields[side]
    local preset = M.presets[shape]
    local data, targets, seen, skipped = M.collect(api, project, regions, chosen), {}, {}, 0
    for _, region in ipairs(regions) do
        if chosen[region.id] and (not region_id or region.id == region_id) then
            local row = data[region.id]
            for _, item in ipairs(side == 'in' and row.in_items or row.out_items) do
                if not seen[item] then
                    seen[item] = true
                    if get(api, item, 'C_LOCK') & 1 ~= 0 then skipped = skipped + 1
                    else
                        local before = {}
                        for i = 1, modern and 4 or 2 do before[i] = get(api, item, keys[i]) end
                        local changed = modern and (not near(before[3], preset.dir_new) or not near(before[4], preset.dir2_new))
                            or not modern and (before[1] ~= shape or not near(before[2], 0))
                        if changed then targets[#targets + 1] = { item = item, before = before } end
                    end
                end
            end
        end
    end
    if #targets == 0 then return 0, skipped end
    api.Undo_BeginBlock2(project)
    api.PreventUIRefresh(1)
    local attempted = {}
    local ok, err = xpcall(function()
        for _, target in ipairs(targets) do
            attempted[#attempted + 1] = target
            local desired = { shape, 0, preset.dir_new, preset.dir2_new }
            -- Setting legacy DIR after SHAPE can destroy a native preset on
            -- recent REAPER. Authoritative new parameters are always written last.
            local order = modern and { 2, 1, 3, 4 } or { 2, 1 }
            for _, i in ipairs(order) do
                assert(api.SetMediaItemInfo_Value(target.item, keys[i], desired[i]), 'Cannot change ' .. keys[i])
            end
        end
    end, debug.traceback)
    local failed = false
    if not ok then
        for _, target in ipairs(attempted) do
            for i = 1, modern and 4 or 2 do
                local restored, result = pcall(api.SetMediaItemInfo_Value, target.item, keys[i], target.before[i])
                if not restored or not result then failed = true end
            end
        end
    end
    api.PreventUIRefresh(-1)
    api.Undo_EndBlock2(project, 'GPhil: change selected region fade-' .. side .. ' curves', -1)
    api.UpdateArrange()
    if not ok then error(tostring(err) .. (failed and '\nRestore incomplete. Use Undo.' or '\nOriginal fade curves restored.')) end
    return #targets, skipped
end
return M
