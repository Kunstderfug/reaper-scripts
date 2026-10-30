-- Run once from the deployed GPhil folder to register actions and enable startup.
-- Preserves existing __startup.lua code and backs it up before adding the stanza.
local api=reaper
local scripts=api.GetResourcePath()..'/Scripts/'
local root=scripts..'GPhil/'
assert(api.file_exists(root..'GPhil_autoOptimizeRecordedCC_start.lua'),'Deploy the automatic CC scripts and lib modules to Scripts/GPhil first.')
local path=scripts..'__startup.lua'
local file=io.open(path,'rb')
local previous=file and file:read('*a') or ''
if file then file:close() end
local first='-- Begin GPhil recorded CC startup'
local last='-- End GPhil recorded CC startup'
local stanza=[[
-- Begin GPhil recorded CC startup
 do
    local root = reaper.GetResourcePath() .. '/Scripts/GPhil/'
    local start = reaper.AddRemoveReaScript(true, 0, root .. 'GPhil_autoOptimizeRecordedCC_start.lua', true)
    reaper.AddRemoveReaScript(true, 0, root .. 'GPhil_autoOptimizeRecordedCC_toggle.lua', true)
    if start > 0 then reaper.Main_OnCommand(start, 0) end
 end
-- End GPhil recorded CC startup
]]
local updated
if previous:find(first,1,true) then
    local a=assert(previous:find(first,1,true))
    local _,b=assert(previous:find(last,a,true))
    updated=previous:sub(1,a-1)..stanza:gsub('\n$','')..previous:sub(b+1)
else updated=previous..'\n'..stanza end
if updated ~= previous then
    if previous ~= '' then
        local backup=path..'.gphil-backup-'..os.date('%Y%m%d_%H%M%S')
        local n=0
        while api.file_exists(backup) do n=n+1;backup=path..'.gphil-backup-'..os.date('%Y%m%d_%H%M%S')..'-'..n end
        local out=assert(io.open(backup,'wb'));assert(out:write(previous));assert(out:close())
    end
    local temp=path..'.gphil-tmp'
    local out=assert(io.open(temp,'wb'));assert(out:write(updated));assert(out:close())
    assert(os.rename(temp,path),'Could not update REAPER startup.')
end
api.SetExtState('GPhil_CC_AfterRecording','enabled','1',true)
local start=api.AddRemoveReaScript(true,0,root..'GPhil_autoOptimizeRecordedCC_start.lua',true)
local toggle=api.AddRemoveReaScript(true,0,root..'GPhil_autoOptimizeRecordedCC_toggle.lua',true)
assert(start>0,'Could not register the background action.')
api.SetToggleCommandState(0,toggle,1)
api.RefreshToolbar2(0,toggle)
if api.GetExtState('GPhil_CC_AfterRecording','owner') == '' then api.Main_OnCommand(start,0) end
