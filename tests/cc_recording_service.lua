-- Toggle lifecycle must stay one-shot, honor persisted Off, and avoid duplicate actions.
local service=dofile('lib/cc_recording_service.lua')
local state,commands,toolbar={}, {}, {}
local api={GetExtState=function(_,key) return state[key] or '' end,
    SetExtState=function(_,key,value,persist) state[key]=value; if key=='enabled' then assert(persist) end end,
    AddRemoveReaScript=function(_,_,path) return path:find('_toggle.lua',1,true) and 10 or 11 end,
    SetToggleCommandState=function(_,id,value) toolbar[id]=value end,RefreshToolbar2=function() end,
    Main_OnCommand=function(id) commands[#commands+1]=id end}
assert(service.enabled(api))
service.toggle(api,'/root/')
assert(state.enabled=='0' and toolbar[10]==0 and #commands==0)
service.start(api,'/root/') -- Persisted Off must not create a monitor or defer loop.
service.toggle(api,'/root/')
assert(state.enabled=='1' and toolbar[10]==1 and #commands==1 and commands[1]==11)
state.owner='live-owner';state.heartbeat='0' -- A modal can stall heartbeat without stopping defer.
service.start(api,'/root/') -- A duplicate internal start is a no-op.
service.toggle(api,'/root/');assert(toolbar[10]==0)
service.toggle(api,'/root/');assert(toolbar[10]==1 and #commands==1)
print('Recording lifecycle: persisted Off, one-shot On/Off toolbar, startup disabled and stale-heartbeat duplicate prevention passed')
