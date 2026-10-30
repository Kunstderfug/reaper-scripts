-- Headless action lifecycle, toggle state, native fitting and verified in-place application.
local M = {}
local here=assert(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])'))
local snapshot=dofile(here..'cc_recording_snapshot.lua')
local diff=dofile(here..'cc_recording_diff.lua')
local scope=dofile(here..'cc_scope.lua')
local native=dofile(here..'cc_native.lua')
local transaction=dofile(here..'cc_transaction.lua')
local watch=dofile(here..'cc_recording_watch.lua')
local section='GPhil_CC_AfterRecording'
local ccs='1,3,11,13,21,22'
function M.enabled(api) return api.GetExtState(section,'enabled') ~= '0' end
local function running(api)
    -- Nonpersistent owner is cleared by atexit (and by REAPER on restart).
    -- A long modal dialog can pause defer/heartbeat; it must not launch a
    -- second instance of an action that is still running.
    return api.GetExtState(section,'owner') ~= ''
end
local function actions(api,root)
    local toggle=api.AddRemoveReaScript(true,0,root..'GPhil_autoOptimizeRecordedCC_toggle.lua',true)
    local start=api.AddRemoveReaScript(true,0,root..'GPhil_autoOptimizeRecordedCC_start.lua',true)
    assert(toggle > 0 and start > 0,'Could not register automatic CC actions.')
    return toggle,start
end
local function toolbar(api,command,on)
    api.SetToggleCommandState(0,command,on and 1 or 0)
    api.RefreshToolbar2(0,command)
end
local function log(api,message)
    local directory=api.GetResourcePath()..'/Data/GPhil'
    api.RecursiveCreateDirectory(directory,0)
    local f=io.open(directory..'/CC-after-recording.log','a')
    if f then f:write(os.date('%Y-%m-%d %H:%M:%S '),message,'\n'); f:close() end
    api.SetExtState(section,'last_result',message,false)
end
function M.toggle(api,root)
    local enabled=not M.enabled(api)
    api.SetExtState(section,'enabled',enabled and '1' or '0',true)
    local toggle,start=actions(api,root)
    toolbar(api,toggle,enabled)
    if enabled and not running(api) then api.Main_OnCommand(start,0) end
end
function M.optimize(api,root,project,baseline)
    assert(api.EnumProjects(-1,'') == project and api.GetPlayStateEx(project) == 0,
        'Project or transport changed; automatic pass skipped.')
    local entries=snapshot.candidates(api,project,baseline)
    if #entries == 0 then return 0 end
    local old={}
    for _, entry in ipairs(entries) do old[entry.take]=entry.old end
    local targets=scope.from_takes(api,project,entries)
    local jobs={}
    for _, target in ipairs(targets) do
        target.plan=diff.prepare(old[target.take],target.before,target.ppq)
        for _, job in ipairs(target.plan.jobs) do jobs[#jobs+1]=job end
    end
    if #jobs == 0 then return 0 end
    native.prepare(api,native.resolve_binary(api,root),jobs,ccs,4,true)
    local changed={}
    for _, target in ipairs(targets) do
        target.after=diff.merge(target.plan)
        if target.after ~= target.before then changed[#changed+1]=target end
    end
    assert(api.EnumProjects(-1,'') == project and api.GetPlayStateEx(project) == 0,
        'Project or transport changed; automatic pass skipped.')
    local count=transaction.apply(api,project,changed,'Auto-optimize recorded CC gestures / CC '..ccs)
    return count
end
function M.start(api,root)
    if not M.enabled(api) or running(api) then return end
    local toggle=actions(api,root)
    local token=api.genGuid()
    api.SetExtState(section,'owner',token,false)
    local watcher=watch.new(api,{
        capture=function(project,previous) return snapshot.capture(api,project,previous) end,
        fingerprint=function(project,baseline)
            local parts={}
            for _, entry in ipairs(snapshot.candidates(api,project,baseline)) do
                local _,hash=api.MIDI_GetHash(entry.take,false,'')
                parts[#parts+1]=tostring(entry.take)..':'..hash
            end
            return table.concat(parts,'|')
        end,
        optimize=function(project,baseline)
            local started=api.time_precise()
            local ok,result=xpcall(function() return M.optimize(api,root,project,baseline) end,debug.traceback)
            log(api,ok and string.format('Optimized %d recorded MIDI sources in %.3f s; tolerance 4; CC %s.',
                result,api.time_precise()-started,ccs) or ('Recording pass skipped/failed: '..result))
        end,
    })
    toolbar(api,toggle,true)
    api.atexit(function()
        if api.GetExtState(section,'owner') == token then
            api.DeleteExtState(section,'owner',false)
            api.DeleteExtState(section,'heartbeat',false)
            toolbar(api,toggle,false)
        end
    end)
    local next_poll=0
    local function loop()
        if not M.enabled(api) or api.GetExtState(section,'owner') ~= token then return end
        local now=api.time_precise()
        api.SetExtState(section,'heartbeat',tostring(now),false)
        if now >= next_poll then
            next_poll=now+.03
            local ok,err=xpcall(function() watcher:poll() end,debug.traceback)
            if not ok then
                watcher:reset()
                log(api,'Monitor reset; recording left unchanged: '..err)
                next_poll=now+1
            end
        end
        api.defer(loop)
    end
    loop()
end
return M
