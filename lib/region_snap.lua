-- Reset opening-item snapping anchors without extending items or editing fades.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local fades = dofile(here .. 'region_fades.lua')

function M.plan(api, project, regions, chosen)
    local plan, seen = { targets = {}, skipped = 0 }, {}
    for _, row in pairs(fades.collect(api, project, regions, chosen)) do
        for _, item in ipairs(row.in_items) do
            if not seen[item] then
                seen[item] = true
                local offset = api.GetMediaItemInfo_Value(item, 'D_SNAPOFFSET')
                if offset ~= 0 then
                    if api.GetMediaItemInfo_Value(item, 'C_LOCK') & 1 ~= 0 then
                        plan.skipped = plan.skipped + 1
                    else plan.targets[#plan.targets + 1] = { item = item, offset = offset } end
                end
            end
        end
    end
    return plan
end

function M.apply(api, project, regions, chosen)
    assert(api.EnumProjects(-1, '') == project, 'Active project changed. Refresh first.')
    assert(api.GetPlayStateEx(project) & 4 == 0, 'Stop recording before resetting snap offsets.')
    local plan = M.plan(api, project, regions, chosen)
    if #plan.targets == 0 then return 0, plan.skipped end
    api.Undo_BeginBlock2(project)
    api.PreventUIRefresh(1)
    local attempted = {}
    local ok, err = xpcall(function()
        for _, target in ipairs(plan.targets) do
            attempted[#attempted + 1] = target
            assert(api.SetMediaItemInfo_Value(target.item, 'D_SNAPOFFSET', 0), 'Cannot reset snap offset.')
        end
    end, debug.traceback)
    local failed = false
    if not ok then
        for _, target in ipairs(attempted) do
            local restored, result = pcall(api.SetMediaItemInfo_Value, target.item, 'D_SNAPOFFSET', target.offset)
            if not restored or not result then failed = true end
        end
    end
    api.PreventUIRefresh(-1)
    api.Undo_EndBlock2(project, 'GPhil: reset opening-item snap offsets in selected regions', -1)
    api.UpdateArrange()
    if not ok then error(tostring(err) .. (failed and '\nRestore incomplete. Use Undo.' or '\nOriginal snap offsets restored.')) end
    return #plan.targets, plan.skipped
end
return M
