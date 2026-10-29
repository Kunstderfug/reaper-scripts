-- One transaction for recorded-item bounds and CC curves, followed by editor UI.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local bounds = dofile(here .. 'midi_item_bounds.lua')
local optimizer = dofile(here .. 'cc_optimizer.lua')

function M.run(api, root, batch, options, services)
    local opt = options or {}
    local edges, curves = bounds, optimizer
    if services then edges, curves = services.bounds, services.optimizer end
    local project = batch.project
    assert(api.EnumProjects(-1, '') == project, 'Recording project is no longer active.')
    assert(api.GetPlayStateEx(project) == 0, 'Transport must be stopped.')
    if #batch.items == 0 then return end
    local plan = edges.plan(api, project, batch.items, 'both', { lead_in = false })
    local originals = {}
    for _, item in ipairs(plan.eligible) do
        local ok, chunk = api.GetItemStateChunk(item, '', false)
        assert(ok, 'Cannot snapshot recorded item; nothing changed.')
        originals[#originals + 1] = { item = item, chunk = chunk }
    end
    local result = { aligned = 0, optimized = 0, report = edges.summary(plan) }
    if #originals > 0 then
        -- Modules keep their verification and refresh balancing; the workflow
        -- owns the encompassing Undo block and full-item rollback.
        local transaction_api = setmetatable({
            Undo_BeginBlock2 = function() end,
            Undo_EndBlock2 = function() end,
        }, { __index = api })
        api.Undo_BeginBlock2(project)
        local ok, err = xpcall(function()
            result.aligned = edges.apply(transaction_api, project, plan)
            if opt.optimize_cc ~= false then
                local optimized = curves.run(transaction_api, root, {
                    prompt = false, scope = 'items', items = plan.eligible,
                    ccs = opt.ccs or 'auto', tolerance = opt.tolerance or 4,
                    jitter = opt.jitter ~= false,
                })
                result.optimized = optimized and optimized.changed or 0
            end
        end, debug.traceback)
        local restored = true
        if not ok then
            for _, original in ipairs(originals) do
                local success, value = pcall(api.SetItemStateChunk, original.item, original.chunk, false)
                restored = restored and success and value == true
            end
        end
        api.Undo_EndBlock2(project, ok and 'GPhil: Prepare recorded MIDI for editing'
            or 'GPhil: Recorded MIDI preparation failed (restore)', -1)
        api.UpdateArrange()
        if not ok then error(tostring(err) .. (restored and '\nRecorded items restored.'
            or '\nItem restoration failed. Use Undo to restore recorded items.'), 0) end
    end
    -- Explicit selection makes the editor action independent of selection left
    -- behind by REAPER's recording/save dialog or a previous editing session.
    api.SelectAllMediaItems(project, false)
    for i, item in ipairs(batch.items) do
        if opt.open_all ~= false or i == 1 then api.SetMediaItemSelected(item, true) end
    end
    api.Main_OnCommandEx(40153, 0, project)
    return result
end
return M
