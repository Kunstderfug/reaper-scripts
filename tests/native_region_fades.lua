-- Run in the current REAPER application; uses a temporary project tab only.
if not reaper then print('native_region_fades: skipped outside REAPER'); return end
local api = reaper
local root = assert(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local fades = dofile(root .. 'lib/region_fades.lua')
local original, project = api.EnumProjects(-1,''), nil
local log = assert(io.open('/tmp/gphil-region-fades-native.txt','w'))
local function near(a,b) assert(math.abs(a-b)<1e-7,tostring(a)..' ~= '..tostring(b)) end
local function get(it,k) return api.GetMediaItemInfo_Value(it,k) end
local pairs = {{0,0},{.5,0},{-.5,0},{1,0},{-1,0},{0,.5},{0,1}}
local ok,err = xpcall(function()
 api.Main_OnCommand(40859,0); project=api.EnumProjects(-1,''); assert(project~=original)
 api.InsertTrackAtIndex(0,false)
 local track=api.GetTrack(project,0)
 local items={}
 for i=1,6 do
  local item=api.AddMediaItemToTrack(track)
  local take=api.AddTakeToMediaItem(item)
  assert(api.SetMediaItemTake_Source(take,assert(api.PCM_Source_CreateFromFile(root .. 'examples/tempo-set-demo/Media/demo.wav'))))
  assert(api.SetMediaItemInfo_Value(item,'D_POSITION',i<=3 and 10+(i-1)*2 or 30+(i-4)*2))
  assert(api.SetMediaItemInfo_Value(item,'D_LENGTH',2))
  assert(api.SetMediaItemInfo_Value(item,'D_FADEINLEN',.4))
  assert(api.SetMediaItemInfo_Value(item,'D_FADEOUTLEN',.3))
  items[i]=item
 end
 local a=api.AddProjectMarker2(project,true,10,16,'A',-1,0)
 local b=api.AddProjectMarker2(project,true,30,36,'B',-1,0)
 local regions={{id=a,first=10,last=16},{id=b,first=30,last=36}}
 local chosen={[a]=true,[b]=true}
 api.Undo_OnStateChangeEx2(project,'Create fade test fixture',-1,-1)
 for shape=0,6 do
  fades.apply(api,project,regions,chosen,a,'in',shape)
  near(get(items[1],'D_FADEINDIR_NEW'),pairs[shape+1][1])
  near(get(items[1],'D_FADEINDIR2_NEW'),pairs[shape+1][2])
  local summary=fades.collect(api,project,regions,chosen)[a].incoming
  assert(not summary.custom and summary.shape==shape)
 end
 local oldout=get(items[3],'D_FADEOUTDIR2_NEW')
 local changed=fades.apply(api,project,regions,chosen,nil,'out',6)
 assert(changed==2)
 near(get(items[3],'D_FADEOUTDIR2_NEW'),1);near(get(items[6],'D_FADEOUTDIR2_NEW'),1)
 api.Undo_DoUndo2(project)
 items={}; for i=0,5 do items[i+1]=api.GetMediaItem(project,i) end
 near(get(items[3],'D_FADEOUTDIR2_NEW'),oldout)
 for i,it in ipairs(items) do
  near(get(it,'D_POSITION'),i<=3 and 10+(i-1)*2 or 30+(i-4)*2)
  near(get(it,'D_LENGTH'),2);near(get(it,'D_FADEINLEN'),.4);near(get(it,'D_FADEOUTLEN'),.3)
 end
 near(get(items[2],'D_FADEINDIR_NEW'),0); near(get(items[5],'D_FADEINDIR_NEW'),0)
 api.SetMediaItemInfo_Value(items[1],'D_FADEINDIR_NEW',.123)
 api.SetMediaItemInfo_Value(items[1],'D_FADEINDIR2_NEW',.321)
 assert(fades.collect(api,project,regions,chosen)[a].incoming.custom)
 log:write('PASS: seven native modern presets, per-region in, all-selected out, custom detection, untouched lengths/positions/internal fades, native Undo\n')
end,debug.traceback)
log:write(ok and 'PASS: all native fade checks\n' or 'FAIL: '..tostring(err)..'\n');log:close()
if project and project~=original and api.EnumProjects(-1,'')==project then
 api.GetSetProjectInfo(project,'DIRTY',0,true);api.Main_OnCommand(40860,0)
end
api.SelectProjectInstance(original)
