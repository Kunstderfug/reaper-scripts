-- Native-engine regression: overdubbing must never refit earlier MIDI.
local diff=dofile('lib/cc_recording_diff.lua')
local native=dofile('lib/cc_native.lua')
local function e(tick,msg,flags) return {tick=tick,msg=msg,flags=flags or 0} end
local function cc(tick,value,lane,channel) return e(tick,string.char(176+(channel or 0),lane or 11,value)) end
local function identity(event) return string.pack('<i8Bs4',event.tick,event.flags,event.msg) end
local old={cc(0,20),e(0,'\255\15CCBZ '..string.char(0)..string.pack('<f',-.3)),
    e(15,string.char(144,60,99)),cc(400,70),e(900,string.char(128,60,0)),e(960,'')}
old[1].flags=80
local recorded={}
for _,event in ipairs(old) do recorded[#recorded+1]=event end
for channel=0,1 do
    for _,lane in ipairs({1,3,11,13,21,22}) do
        for t=100,300,10 do recorded[#recorded+1]=cc(t,20+(t-100)//5,lane,channel) end
        for t=500,700,10 do recorded[#recorded+1]=cc(t,70-(t-500)//5,lane,channel) end
    end
end
recorded[#recorded+1]=cc(250,127,64) -- sustain is never optimized
-- Stable ordering and exact preservation of selected notes and old CC metadata.
for i,event in ipairs(recorded) do event.order=i end
recorded[3].flags=1
 table.sort(recorded,function(a,b) return a.tick<b.tick or a.tick==b.tick and a.order<b.order end)
local original=diff.pack(recorded)
local plan=diff.prepare({diff.pack(old)},original,960)
assert(#plan.jobs==13,'One run per CC/channel plus a split at the earlier CC11 anchor')
local api={ExecProcess=function(command)
    local p=assert(io.popen(command..' 2>&1'));local out=p:read('*a');local ok,_,code=p:close()
    return tostring(ok and 0 or code)..'\n'..out
end}
native.prepare(api,'tools/rpp-curve-opt/target/release/rpp-curve-opt',plan.jobs,'1,3,11,13,21,22',4,true)
local result=diff.merge(plan)
local output=diff.parse(result)
local present={}
for _,event in ipairs(output) do present[identity(event)]=(present[identity(event)] or 0)+1 end
for _,event in ipairs(old) do assert(present[identity(event)],'Earlier MIDI changed') end
assert(present[identity(cc(250,127,64))],'Excluded CC changed')
assert(#output < #recorded/3,'Expected substantial reduction in newly recorded straight ramps')
-- No additions: exact no-op even when UI selection flags changed.
local selected={}
for _,event in ipairs(recorded) do selected[#selected+1]=e(event.tick,event.msg,event.flags | 1) end
local unchanged=diff.pack(selected)
local no_op=diff.prepare({original},unchanged,960)
assert(#no_op.jobs==0 and diff.merge(no_op)==unchanged)
-- The final anchor's outgoing shape/tension must stay unchanged.
local last={cc(0,0),cc(20,10),cc(40,20),cc(60,30)}
last[4].flags=80
last[5]=e(60,'\255\15CCBZ '..string.char(0)..string.pack('<f',.2))
last[6]=e(100,'')
local p=diff.prepare({},diff.pack(last),960)
native.prepare(api,'tools/rpp-curve-opt/target/release/rpp-curve-opt',p.jobs,'11',4,true)
local merged=diff.parse(diff.merge(p))
local found={};for _,event in ipairs(merged) do found[identity(event)]=true end
assert(found[identity(last[4])] and found[identity(last[5])])
print(string.format('Recorded CC native fitting: %d -> %d events; 6 lanes, 2 channels, old MIDI/notes/metadata, boundaries, selection and sustain preserved',#recorded,#output))

local watch=dofile('lib/cc_recording_watch.lua')
local time,state,project,runs,captures=0,0,1,0,0
local watcher=watch.new({EnumProjects=function() return project end,time_precise=function() return time end,
    GetPlayStateEx=function() return state end}, {
    capture=function() captures=captures+1;return {id=captures} end,
    fingerprint=function() return 'stable' end,
    optimize=function() runs=runs+1 end,
})
local function poll(t,s) time,state=t,s;watcher:poll() end
poll(0,0);poll(.2,1);poll(.4,0);poll(1,0);assert(runs==0)
poll(2,5);poll(3,0);poll(3.5,0);assert(runs==0);poll(4,0);assert(runs==1)
poll(5,5);poll(6,1);poll(7,1);assert(runs==1);poll(8,0);poll(8.5,0);poll(9,0);assert(runs==2)
poll(10,5);project=2;poll(11,0);poll(12,0);assert(runs==2)
local w=watch.new({EnumProjects=function() return 1 end,time_precise=function() return time end,
    GetPlayStateEx=function() return state end}, {capture=function() return {} end,
    fingerprint=function() return '' end,optimize=function() error('Started during recording') end})
state=5;w:poll();state=0;time=20;w:poll();time=21;w:poll()
print('Transport watcher: playback ignored, recording stop waits for stable data, playback continuation deferred, project switch and mid-record startup skipped')

local snapshot=dofile('lib/cc_recording_snapshot.lua')
local a={id='a',data='old',origin=0};local item={a};local track={item}
local api={CountTracks=function() return 1 end,GetTrack=function() return track end,
    GetMediaTrackInfo_Value=function() return 1 end,CountTrackMediaItems=function() return #track end,
    GetTrackMediaItem=function(_,i) return track[i+1] end,CountTakes=function(it) return #it end,
    GetTake=function(it,i) return it[i+1] end,TakeIsMIDI=function() return true end,
    GetSetMediaItemTakeInfo_String=function(t) return true,t.id end,
    MIDI_GetHash=function(t) return true,t.data end,MIDI_GetAllEvts=function(t) return true,t.data end,
    MIDI_GetProjQNFromPPQPos=function(t,pos) return t.origin+pos/960 end}
local base=snapshot.capture(api,1)
a.data='overdub';assert(#snapshot.candidates(api,1,base)==1)
local candidate=snapshot.candidates(api,1,base)[1];assert(candidate.old[1]=='old')
a.origin=1;assert(#snapshot.candidates(api,1,base)==0);a.origin=0
local b={id='b',data='new take',origin=0};item[2]=b
local candidates=snapshot.candidates(api,1,base)
assert(#candidates==2 and candidates[2].old[1]=='old','New take must protect copied older MIDI')
track[2]={{id='c',data='new item',origin=5}}
candidates=snapshot.candidates(api,1,base)
assert(#candidates==3 and #candidates[3].old==0)
print('Recording snapshots: changed take, copied overdub take and new item isolated; changed source mapping skipped')
