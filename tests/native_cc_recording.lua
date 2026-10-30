-- Disposable native proof. Run as a ReaScript; never touches the existing project.
local root=assert(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local api=reaper
local diff=dofile(root..'lib/cc_recording_diff.lua')
local snapshot=dofile(root..'lib/cc_recording_snapshot.lua')
local service=dofile(root..'lib/cc_recording_service.lua')
local verify=dofile(root..'lib/cc_verify.lua')
local previous=api.EnumProjects(-1,'')
local f=assert(io.open('/tmp/gphil-cc-recording-native.txt','w'))
local function log(s) f:write(s,'\n');f:flush() end
local ok,err=xpcall(function()
    api.Main_OnCommand(40859,0)
    local project=api.EnumProjects(-1,'')
    assert(project ~= previous and api.CountTracks(project)==0,'Expected disposable blank project')
    local targets={}
    for tracknum=0,1 do
        api.InsertTrackAtIndex(tracknum,false)
        local track=api.GetTrack(project,tracknum)
        api.GetSetMediaTrackInfo_String(track,'P_NAME','Post-record CC test '..tracknum,true)
        api.SetMediaTrackInfo_Value(track,'I_RECARM',1)
        local item=api.CreateNewMIDIItemInProj(track,0,8,true)
        local take=api.GetActiveTake(item)
        local events={
            {tick=0,flags=16,msg=string.char(176,11,20)},
            {tick=15,flags=1,msg=string.char(144,60+tracknum,99)},
            {tick=400,flags=0,msg=string.char(176,11,70)},
            {tick=900,flags=0,msg=string.char(128,60+tracknum,0)},
            {tick=7680,flags=0,msg=string.char(176,123,0)},
        }
        assert(api.MIDI_SetAllEvts(take,diff.pack(events)))
        targets[#targets+1]={item=item,take=take}
    end
    local baseline=snapshot.capture(api,project)
    for _,target in ipairs(targets) do
        local _,data=api.MIDI_GetAllEvts(target.take,'')
        local events=diff.parse(data)
        target.old=events
        for _,lane in ipairs({1,3,11,13,21,22}) do
            for tick=100,300,10 do events[#events+1]={tick=tick,flags=0,msg=string.char(176,lane,20+(tick-100)//5)} end
            for tick=500,700,10 do events[#events+1]={tick=tick,flags=0,msg=string.char(176,lane,70-(tick-500)//5)} end
        end
        for i,event in ipairs(events) do event.order=i end
        table.sort(events,function(a,b) return a.tick < b.tick or a.tick==b.tick and a.order<b.order end)
        assert(api.MIDI_SetAllEvts(target.take,diff.pack(events)))
        local _,before=api.MIDI_GetAllEvts(target.take,'')
        target.before=before
    end
    api.Undo_OnStateChangeEx2(project,'Recorded MIDI test setup',-1,-1)
    local started=api.time_precise()
    assert(service.optimize(api,root,project,baseline)==2)
    log(string.format('PASS: native automatic fitting of 2 overdubbed sources, six CC lanes, %.3f s',api.time_precise()-started))
    assert(api.Undo_CanUndo2(project)=='Auto-optimize recorded CC gestures / CC 1,3,11,13,21,22')
    for _,target in ipairs(targets) do
        local _,after=api.MIDI_GetAllEvts(target.take,'')
        assert(#after < #target.before/2,'Expected substantial reduction')
        local old=baseline.takes[select(2,api.GetSetMediaItemTakeInfo_String(target.take,'GUID','',false))].data
        local expected={}
        for _,event in ipairs(diff.parse(old)) do
            expected[string.pack('<i8Bs4',event.tick,event.flags,event.msg)]=true
        end
        for _,event in ipairs(diff.parse(after)) do expected[string.pack('<i8Bs4',event.tick,event.flags,event.msg)]=nil end
        assert(next(expected)==nil,'Earlier MIDI changed')
        log(string.format('PASS: earlier notes/CC/timing/flags preserved; %d -> %d bytes',#target.before,#after))
    end
    api.Undo_DoUndo2(project)
    for i,target in ipairs(targets) do
        local item=api.GetTrackMediaItem(api.GetTrack(project,i-1),0)
        local take=api.GetActiveTake(item)
        local _,actual=api.MIDI_GetAllEvts(take,'')
        assert(verify.matches(target.before,actual),'One Undo did not restore recorded MIDI')
    end
    log('PASS: ONE native Undo restored both complete post-record MIDI buffers')
    api.Main_SaveProjectEx(project,'/tmp/gphil-cc-recording-native.RPP',0)
end,debug.traceback)
if not ok then log('FAIL: '..tostring(err)) end
if previous then api.SelectProjectInstance(previous) end
f:close()
