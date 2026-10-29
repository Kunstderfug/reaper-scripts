local selection=dofile('lib/cc_selection.lua')
local state={ items={}, tracks={}, revision=1, project=1 }
local api={
    EnumProjects=function() return state.project end,
    GetProjectStateChangeCount=function() return state.revision end,
    CountSelectedMediaItems=function() return #state.items end,
    GetSelectedMediaItem=function(_,i) return state.items[i+1] end,
    GetActiveTake=function(item) return item.take end,
    TakeIsMIDI=function(take) return take=='midi' end,
    CountSelectedTracks=function() return #state.tracks end,
    GetSelectedTrack=function(_,i) return state.tracks[i+1] end,
}
local a=selection.snapshot(api)
assert(selection.resolve(a)=='items') -- Never assume whole project.
state.tracks={1,2}
local b=selection.snapshot(api)
assert(selection.resolve(b,a,'items')=='tracks')
assert(not selection.same(a,b) and a.revision==b.revision) -- Selection need not dirty project.
state.items={{take='midi'}}
local c=selection.snapshot(api)
assert(selection.resolve(c,b,'tracks')=='items')
state.tracks={1,2,3}
local d=selection.snapshot(api)
assert(selection.resolve(d,c,'items')=='tracks') -- Latest explicit track selection wins.
state.items[#state.items+1]={take='midi'}
local e=selection.snapshot(api)
assert(selection.resolve(e,d,'tracks')=='items')
state.items={{take='audio'}}
local f=selection.snapshot(api)
assert(f.item_count==0 and selection.resolve(f,e,'items')=='tracks')
state.project=2; state.items={{take='midi'}}
local g=selection.snapshot(api)
assert(selection.resolve(g,f,'tracks')=='items' and not selection.same(g,f))
assert(selection.same(g,selection.snapshot(api)))
state.revision=2
assert(not selection.same(g,selection.snapshot(api)))
print('CC selection: live signatures, MIDI-only auto scope, latest selection, project switch and revision guards passed')
