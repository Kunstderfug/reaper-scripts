-- End-to-end disposable VKB MIDI overdub + actual transport-stop background action.
local root=assert(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local api=reaper
local diff=dofile(root..'lib/cc_recording_diff.lua')
local verify=dofile(root..'lib/cc_verify.lua')
local section='GPhil_CC_AfterRecording'
local previous=api.EnumProjects(-1,'')
local f=assert(io.open('/tmp/gphil-cc-recording-transport.txt','w'))
local function log(s) f:write(s,'\n');f:flush() end
assert(api.GetPlayStateEx(previous)==0,'Stop transport first')
api.Main_OnCommand(40859,0)
local project=api.EnumProjects(-1,'')
assert(api.CountTracks(project)==0)
api.InsertTrackAtIndex(0,false)
local track=api.GetTrack(project,0)
api.GetSetMediaTrackInfo_String(track,'P_NAME','AUTOMATIC CC RECORDING PROOF',true)
api.SetMediaTrackInfo_Value(track,'I_RECARM',1)
api.SetMediaTrackInfo_Value(track,'I_RECINPUT',4096+62*32)
api.SetMediaTrackInfo_Value(track,'I_RECMODE',7)
api.SetMediaTrackInfo_Value(track,'I_RECMON',1)
api.SetOnlyTrackSelected(track)
local item=api.CreateNewMIDIItemInProj(track,0,8,true)
local take=api.GetActiveTake(item)
local old={
    {tick=0,flags=16,msg=string.char(176,11,37)},
    {tick=10,flags=0,msg=string.char(144,60,90)},
    {tick=100,flags=0,msg=string.char(128,60,0)},
    {tick=7000,flags=16,msg=string.char(176,11,70)},
    {tick=7680,flags=0,msg=string.char(176,123,0)},
}
assert(api.MIDI_SetAllEvts(take,diff.pack(old)))
api.Undo_OnStateChangeEx2(project,'Setup disposable overdub',-1,-1)
api.SetExtState(section,'enabled','1',true)
local start=api.AddRemoveReaScript(true,0,root..'GPhil_autoOptimizeRecordedCC_start.lua',true)
api.Main_OnCommand(start,0)
local since=api.time_precise()
local stage,next_event,before,stopped=0,1,nil,nil
local done=false
local function finish(ok,message)
    done=true
    if api.GetPlayStateEx(project)~=0 then api.OnStopButton() end
    if api.ValidatePtr2(project,track,'MediaTrack*') then api.SetMediaTrackInfo_Value(track,'I_RECARM',0) end
    api.SetExtState(section,'enabled','0',true)
    log((ok and 'PASS: ' or 'FAIL: ')..message)
    api.Main_SaveProjectEx(project,'/tmp/gphil-cc-recording-transport.RPP',0)
    api.SelectProjectInstance(previous)
    f:close()
end
api.atexit(function() if not done then finish(false,'Test interrupted') end end)
local function step()
    local ok,err=xpcall(function()
        local elapsed=api.time_precise()-since
        if stage==0 and elapsed>.3 then
            api.SetEditCurPos2(project,.2,false,false)
            api.Main_OnCommand(1013,0)
            assert(api.GetPlayStateEx(project)&4~=0,'Transport did not start recording')
            since=api.time_precise();stage=1
            log('Recording started in MIDI overdub mode')
        elseif stage==1 then
            if api.GetPlayPositionEx(project)>.3 and next_event<=40 and elapsed>.15+(next_event-1)*.025 then
                for _,cc in ipairs({1,3,11,13,21,22}) do api.StuffMIDIMessage(0,176,cc,20+next_event*2) end
                next_event=next_event+1
            elseif next_event>40 and elapsed>1.3 then
                api.OnStopButton()
                assert(api.GetPlayStateEx(project)==0,'Transport did not stop')
                take=api.GetActiveTake(api.GetTrackMediaItem(track,0))
                local read;read,before=api.MIDI_GetAllEvts(take,'');assert(read)
                log('Recorded '..#diff.parse(before)..' events; items '..api.CountTrackMediaItems(track)..'; takes '..api.CountTakes(item))
                assert(#diff.parse(before)>200,'VKB recording produced too few CCs')
                stage=2;stopped=api.time_precise()
                log('Actual recording stopped; '..#before..' bytes before automatic optimization')
            end
        elseif stage==2 then
            if api.Undo_CanUndo2(project)=='Auto-optimize recorded CC gestures / CC 1,3,11,13,21,22' then
                take=api.GetActiveTake(api.GetTrackMediaItem(track,0))
                local _,after=api.MIDI_GetAllEvts(take,'')
                assert(#after<#before/2,'Automatic optimization did not reduce the recording')
                local preserved={}
                for _,event in ipairs(old) do preserved[string.pack('<i8Bs4',event.tick,event.flags,event.msg)]=true end
                for _,event in ipairs(diff.parse(after)) do preserved[string.pack('<i8Bs4',event.tick,event.flags,event.msg)]=nil end
                assert(next(preserved)==nil,'An earlier MIDI event changed')
                log('Earlier CC, notes, timing and flags preserved; '..#before..' -> '..#after..' bytes')
                api.Undo_DoUndo2(project)
                take=api.GetActiveTake(api.GetTrackMediaItem(api.GetTrack(project,0),0))
                local _,actual=api.MIDI_GetAllEvts(take,'')
                assert(verify.matches(before,actual),'One Undo did not restore recorded MIDI')
                finish(true,string.format('Actual stop-triggered optimization + one-step Undo, %.3f s after stop',api.time_precise()-stopped))
            elseif api.time_precise()-stopped>6 then
                error('No automatic pass: '..api.GetExtState(section,'last_result'))
            end
        end
    end,debug.traceback)
    if not ok then finish(false,err) end
    if not done then api.defer(step) end
end
step()
