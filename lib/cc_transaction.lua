-- One verified MIDI transaction shared by manual and post-record optimization.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local verify = dofile(here .. 'cc_verify.lua')
function M.apply(api, project, changed, label)
    if #changed == 0 then return 0 end
    assert(api.GetPlayStateEx(project) & 4 == 0, 'Stop recording before applying MIDI changes.')
    for _, target in ipairs(changed) do
        local ok, current = api.MIDI_GetAllEvts(target.take, '')
        assert(ok and current == target.before, 'MIDI changed during preparation; no optimization was applied.')
    end
    api.Undo_BeginBlock2(project)
    api.PreventUIRefresh(1)
    local touched = {}
    local ok, err = xpcall(function()
        for _, target in ipairs(changed) do
            touched[#touched + 1] = target
            assert(api.MIDI_SetAllEvts(target.take, target.after), 'Could not apply MIDI result.')
            local read_ok, actual = api.MIDI_GetAllEvts(target.take, '')
            if not read_ok or not verify.matches(target.after,actual) then error(verify.failure(api,target,read_ok and actual or nil),0) end
            api.UpdateItemInProject(target.item)
            api.MIDI_RefreshEditors(target.take)
        end
    end, debug.traceback)
    local rollback_failed = false
    if not ok then
        for _, target in ipairs(touched) do
            local restored, verified = pcall(function()
                assert(api.MIDI_SetAllEvts(target.take, target.before))
                local read_ok, data = api.MIDI_GetAllEvts(target.take, '')
                api.MIDI_RefreshEditors(target.take)
                return read_ok and verify.matches(target.before,data)
            end)
            rollback_failed = rollback_failed or not restored or not verified
        end
    end
    api.PreventUIRefresh(-1)
    api.Undo_EndBlock2(project, ok and label or 'CC optimization failed — restored', -1)
    api.UpdateArrange()
    if not ok then error(err .. (rollback_failed and '\nRestore verification failed: use Undo to restore the original MIDI.' or '\nOriginal MIDI restored.'), 0) end
    return #changed
end
return M
