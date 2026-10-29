-- Scope/controller orchestration and one-step native MIDI transaction.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local scope_module = dofile(here .. 'cc_scope.lua')
local native = dofile(here .. 'cc_native.lua')
local verify = dofile(here .. 'cc_verify.lua')
local function backup(api, project, filename)
    assert(filename ~= '', 'Save the project once before whole-project optimization.')
    local stem = filename:gsub('%.[Rr][Pp][Pp]$', '')
    local base = stem .. '_CC_BACKUP_' .. os.date('%Y%m%d_%H%M%S')
    local path, n = base .. '.RPP', 1
    while api.file_exists(path) do n = n + 1; path = base .. '_' .. n .. '.RPP' end
    local dirty = api.IsProjectDirty(project) ~= 0
    api.Main_SaveProjectEx(project, path, 0)
    if dirty then api.MarkProjectDirty(project) end
    local f = io.open(path, 'rb')
    assert(f, 'Backup failed; no MIDI was changed.')
    local size = f:seek('end'); f:close()
    assert(size and size > 0, 'Backup is empty; no MIDI was changed.')
    return path
end
function M.run(api, root, options)
    local opt = options or {}
    local project, filename = api.EnumProjects(-1, '')
    assert(project, 'No current project.')
    assert(api.GetPlayStateEx(project) & 4 == 0, 'Stop recording before optimizing CC curves.')
    local binary = native.resolve_binary(api, root, opt.binary)
    local scope, ccs, tolerance, jitter = opt.scope or 'items', opt.ccs or 'auto', opt.tolerance or 4, opt.jitter ~= false
    if opt.prompt ~= false then
        local ok, values = api.GetUserInputs('Optimize CC gestures — one Undo step', 4,
            'Scope (items / tracks / project),CC lanes (auto / numbers / continuous),Curve tolerance (MIDI values),Repair jitter and fades (y/n),extrawidth=240',
            'items,auto,4,y')
        if not ok then return nil end
        local tol, jit; scope, ccs, tol, jit = values:match('^(.-),(.-),(.-),(.-)$')
        assert(scope, 'Invalid settings.')
        tolerance = tonumber(tol)
        assert(jit:lower():match('^[yn]$'), 'Use y or n for jitter repair.')
        jitter = jit:lower() == 'y'
    end
    scope = scope:lower():gsub('%s+', '')
    ccs = ccs:lower():gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ',')
    assert(tolerance and tolerance > 0 and tolerance <= 16, 'Tolerance must be >0 and <=16.')
    assert(ccs == 'auto' or ccs == 'continuous' or ccs:match('^%d+[,0-9]*$'), 'Use auto, continuous, or space-separated CC numbers.')
    local started = api.time_precise()
    local targets = scope_module.collect(api, project, scope, opt.items)
    if ccs == 'auto' then
        local excluded
        ccs, excluded = scope_module.detect_ccs(targets)
        api.ShowConsoleMsg('Auto CC lanes in ' .. scope .. ': ' .. (ccs ~= '' and ccs or 'none')
            .. (excluded ~= '' and ('; excluded switch/data lanes: ' .. excluded) or '') .. '\n')
        if ccs == '' then return { changed = 0, ccs = '' } end
    end
    local log = native.prepare(api, binary, targets, ccs, tolerance, jitter)
    local changed = {}
    for _, target in ipairs(targets) do
        local ok, current = api.MIDI_GetAllEvts(target.take, '')
        assert(ok and current == target.before, 'MIDI changed during preparation; no optimization was applied.')
        if target.before ~= target.after then changed[#changed + 1] = target end
    end
    if #changed == 0 then api.ShowConsoleMsg('CC optimization: no changes needed.\n'); return { changed = 0 } end
    local backup_path
    if scope == 'project' then backup_path = backup(api, project, filename) end
    local label = 'Optimize CC gestures: ' .. scope .. ' / CC ' .. ccs
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
    if scope == 'project' then
        api.Main_SaveProject(project, false)
        local _, current_name = api.EnumProjects(-1, '')
        assert(current_name == filename and api.IsProjectDirty(project) == 0,
            'MIDI optimized, but saving the current filename did not finish. Backup: ' .. backup_path .. '. Undo remains available.')
    end
    local seconds = api.time_precise() - started
    api.ShowConsoleMsg(string.format('Optimized %d MIDI sources in %.3f s. Undo: %s\n%s%s\n',
        #changed, seconds, label, backup_path and ('Backup: ' .. backup_path .. '\n') or '', log))
    return { changed = #changed, label = label, seconds = seconds, backup = backup_path, report = log, ccs = ccs }
end
return M
