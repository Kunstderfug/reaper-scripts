-- Scope, preflight, transaction rollback, and backup-before-save behavior.
local module = dofile('lib/cc_optimizer.lua')
local function mock()
    local state = { begin=0, finish=0, sets=0, saved=false, events={}, refresh=0 }
    local items = {{id=1,track=1,data='original1'}, {id=2,track=1,data='original2'}, {id=3,track=2,data='original3'}}
    local filename = os.tmpname() .. '.RPP'
    local api = {
        EnumProjects=function() return 123,filename end,
        GetPlayStateEx=function() return 0 end,
        file_exists=function(path) if path=='/bundle/bin/rpp-curve-opt' then return true end local f=io.open(path,'rb');if f then f:close();return true end return false end,
        CountSelectedMediaItems=function() return 1 end, GetSelectedMediaItem=function() return items[1] end,
        CountSelectedTracks=function() return 1 end, GetSelectedTrack=function() return 1 end,
        CountTrackMediaItems=function() return 2 end, GetTrackMediaItem=function(_,i) return items[i+1] end,
        CountMediaItems=function() return #items end, GetMediaItem=function(_,i) return items[i+1] end,
        GetActiveTake=function(item) return item end, TakeIsMIDI=function() return true end,
        GetMediaItemTake_Source=function(take) return take.id end, GetMediaSourceFileName=function() return '' end,
        BR_GetMidiTakePoolGUID=function(take) return true,tostring(take.pool or take.id) end,
        CountTakes=function() return 1 end, GetTake=function(item) return item end,
        MIDI_GetAllEvts=function(take) return true,take.data end,
        MIDI_GetProjQNFromPPQPos=function() return 0 end, MIDI_GetPPQPosFromProjQN=function(_,qn) return qn*960 end,
        time_precise=function() return 10 end, ShowConsoleMsg=function(msg) state.log=(state.log or '')..msg end,
        Undo_BeginBlock2=function() state.begin=state.begin+1 end,
        Undo_EndBlock2=function(_,label) state.finish=state.finish+1;state.label=label end,
        PreventUIRefresh=function(n) state.refresh=state.refresh+n end, UpdateArrange=function() end, UpdateItemInProject=function() end,
        MIDI_RefreshEditors=function() end,
        MIDI_SetAllEvts=function(take,data)
            state.sets=state.sets+1
            if state.fail_apply and state.sets==2 then take.data='partial';return false end
            take.data=data;return true
        end,
        IsProjectDirty=function() return state.saved and 0 or 1 end, MarkProjectDirty=function() state.dirty=true end,
        Main_SaveProjectEx=function(_,path,flags)
            assert(flags==0 and state.sets==0)
            state.backup=path
            if not state.fail_backup then local f=assert(io.open(path,'wb'));f:write('backup original');f:close() end
        end,
        Main_SaveProject=function() assert(state.backup);state.saved=true end,
        GetUserInputs=function() return false,'' end,
        ExecProcess=function(command)
            state.command=command
            assert(command:find('--keep-snapshots',1,true) and command:find('--native-batch',1,true))
            assert(not command:find('--snapshots-only',1,true))
            if state.fail_process then return '1\nFailure' end
            local paths={};for p in command:gmatch('"([^"]+)"') do paths[#paths+1]=p end
            local f=assert(io.open(paths[2],'rb'));local data=f:read('*a');f:close()
            local count,pos=string.unpack('<I4',data,5);local output={'GCC1',string.pack('<I4',count)}
            for i=1,count do
                local ppq,len;ppq,len,pos=string.unpack('<I4I8',data,pos)
                local changed='optimized:'..data:sub(pos,pos+len-1);pos=pos+len
                output[#output+1]=string.pack('<I4I8',ppq,#changed)..changed
            end
            local f=assert(io.open(paths[3],'wb'));f:write(table.concat(output));f:close();return '0\nSuccess'
        end,
    }
    return api,state,items
end
local function run(api,scope) return module.run(api,'/bundle/',{prompt=false,scope=scope,ccs='11'}) end
local api,s,items=mock();local r=run(api,'items')
assert(r.changed==1 and items[1].data=='optimized:original1' and items[2].data=='original2' and items[3].data=='original3')
assert(s.begin==1 and s.finish==1 and s.refresh==0 and not s.saved and not s.backup)
local api,s,items=mock();assert(run(api,'tracks').changed==2);assert(items[3].data=='original3')
local api,s=mock();assert(run(api,'project').changed==3);assert(s.saved and s.dirty);os.remove(s.backup)
local api,s,items=mock();s.fail_apply=true;assert(not pcall(run,api,'tracks'))
for i,item in ipairs(items) do assert(item.data=='original'..i) end
assert(s.refresh==0 and s.begin==1 and s.finish==1)
local api,s=mock();s.fail_process=true;assert(not pcall(run,api,'items'));assert(s.begin==0 and s.sets==0)
local api,s=mock();s.fail_backup=true;assert(not pcall(run,api,'project'));assert(s.begin==0 and s.sets==0)
local api,s,items=mock();items[2].pool=1;assert(not pcall(run,api,'items'));assert(s.begin==0 and s.sets==0)
local api,s=mock();assert(module.run(api,'/bundle/')==nil);assert(s.begin==0 and s.sets==0)
print('CC integration: item/track/project scopes, single transaction, rollback, pooled guard, process/backup failure and cancel passed')
local function cc(number) return string.pack('<i4Bs4',0,0,string.char(176,number,64)) end
local api,s,items=mock()
items[1].data=cc(11)..cc(1)..cc(64)..cc(0)
items[2].data=cc(22)..cc(11)
items[3].data=cc(13)
local r=module.run(api,'/bundle/',{prompt=false,scope='tracks',ccs='auto'})
assert(r.ccs=='1,11,22' and s.command:find('--cc "1,11,22"',1,true))
assert(items[3].data==cc(13) and s.log:find('excluded switch/data lanes: 0,64',1,true))
local api,s,items=mock();items[1].data=cc(64)..cc(123)
local r=module.run(api,'/bundle/',{prompt=false,scope='items'})
assert(r.changed==0 and s.begin==0 and s.sets==0 and not s.command)
print('CC auto detection: scoped union, numeric sorting, excluded switch/data lanes and empty result passed')
