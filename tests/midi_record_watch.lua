local module = dofile('lib/midi_record_watch.lua')
local function fixture()
    local armed, other = { armed = 1 }, { armed = 0 }
    local project = { items = {}, tracks = { armed, other }, state = 0, revision = 0 }
    local current, now = project, 0
    local reads = {}
    local function item(track, data, audio)
        local value = { track = track or armed, take = { data = data or 'notes', audio = audio } }
        project.items[#project.items + 1] = value
        project.revision = project.revision + 1
        return value
    end
    local api = {
        EnumProjects = function() return current end,
        GetPlayStateEx = function(p) return p.state end,
        time_precise = function() return now end,
        GetProjectStateChangeCount = function(p) return p.revision end,
        CountMediaItems = function(p) return #p.items end,
        GetMediaItem = function(p, i) return p.items[i + 1] end,
        GetActiveTake = function(it) return it.take end,
        TakeIsMIDI = function(t) return not t.audio end,
        MIDI_GetAllEvts = function(t) reads[t] = (reads[t] or 0) + 1; return true, t.data end,
        CountTracks = function(p) return #p.tracks end,
        GetTrack = function(p, i) return p.tracks[i + 1] end,
        GetMediaTrackInfo_Value = function(t) return t.armed end,
        GetMediaItemTrack = function(it) return it.track end,
    }
    local watch = module.new(api)
    local function poll(state, advance)
        if state then current.state = state end
        now = now + (advance or 0)
        return watch.poll()
    end
    return { project = project, armed = armed, other = other, item = item, poll = poll, api = api, reads = reads,
        switch = function(p) current = p end }
end

-- First defer after recording begins can already contain the recorded item.
local f = fixture()
local old = f.item()
assert(not f.poll(0))
local new = f.item()
assert(not f.poll(5))
assert(not f.poll(0))
assert(not f.poll(0, .1))
local batch = assert(f.poll(0, .11))
assert(batch.project == f.project and #batch.items == 1 and batch.items[1] == new)
assert(not f.poll(0, 1), 'A batch must be returned only once.')

-- Existing-item overdubs and new active takes are identified independently.
f = fixture()
local overdub, retake, unchanged = f.item(), f.item(), f.item()
f.poll(0); f.poll(5)
overdub.take.data = 'new notes'
retake.take = { data = 'new take' }
f.poll(0)
batch = assert(f.poll(0, .21))
assert(#batch.items == 2 and batch.items[1] == overdub and batch.items[2] == retake)

-- Audio and edits on unarmed tracks do not get processed, even if selected.
f = fixture()
local unrelated = f.item(f.other)
f.poll(0); f.poll(5)
f.item(f.armed, 'audio', true)
unrelated.take.data = 'edited notes'
f.item(f.other)
f.poll(0)
assert(not f.poll(0, .21))

-- Deleting a cancelled recording produces no stale pointer in a batch.
f = fixture()
f.poll(0); f.poll(5); f.item()
f.project.items = {}
f.poll(0)
assert(not f.poll(0, .21))

-- Pause and playback after recording defer processing until a full stop.
f = fixture()
f.poll(0); f.poll(5); new = f.item()
assert(not f.poll(6, 1))
assert(not f.poll(2, 1))
assert(not f.poll(1, 1))
assert(not f.poll(0))
assert(f.poll(0, .21).items[1] == new)

-- A fresh recording interrupts the settling timer without losing its baseline.
f = fixture()
f.poll(0); f.poll(5); new = f.item(); f.poll(0)
f.poll(5, .1); f.poll(0, 1)
assert(not f.poll(0, .1))
assert(f.poll(0, .11).items[1] == new)

-- Changes made while idle belong to the baseline, not the next recording.
f = fixture()
f.poll(0); old = f.item(); f.poll(0); f.poll(5)
new = f.item(); f.poll(0)
batch = assert(f.poll(0, .21))
assert(#batch.items == 1 and batch.items[1] == new)

-- Switching project tabs abandons a session rather than mutating another tab.
f = fixture()
f.poll(0); f.poll(5); f.item(); f.poll(0)
f.switch({ items = {}, tracks = {}, state = 0, revision = 0 })
assert(not f.poll(0, 1))
f.switch(f.project)
assert(not f.poll(0, 1))

-- Enabling during recording cannot reconstruct its pre-recording baseline.
f = fixture()
f.item(); f.poll(5); f.item(); f.poll(0)
assert(not f.poll(0, .21))
f.poll(5); new = f.item(); f.poll(0)
assert(f.poll(0, .21).items[1] == new)

-- Idle refreshes read MIDI only on armed tracks, and stable polls do no reads.
f = fixture()
local armed_item, unarmed_item = f.item(), f.item(f.other)
f.poll(0)
assert(f.reads[armed_item.take] == 1 and not f.reads[unarmed_item.take])
f.poll(0)
assert(f.reads[armed_item.take] == 1)
f.project.revision = f.project.revision + 1
f.poll(0)
assert(f.reads[armed_item.take] == 2 and not f.reads[unarmed_item.take])

-- Changing record arm refreshes baselines even without a project revision.
f.other.armed = 1
f.poll(0)
assert(f.reads[unarmed_item.take] == 1)
f.poll(5)
unarmed_item.take.data = 'overdub on newly armed track'
f.poll(0)
batch = assert(f.poll(0, .21))
assert(#batch.items == 1 and batch.items[1] == unarmed_item)
f.other.armed = 0
local previous_reads = f.reads[unarmed_item.take]
f.poll(0)
assert(f.reads[unarmed_item.take] == previous_reads)

-- The native hash path detects overdubs without copying MIDI buffers to Lua.
f = fixture()
local hashes = {}
f.api.MIDI_GetHash = function(take, notes_only, seed)
    assert(notes_only == false and seed == '')
    hashes[take] = (hashes[take] or 0) + 1
    return true, 'hash:' .. take.data
end
overdub, unchanged = f.item(), f.item(f.other)
f.poll(0)
assert(hashes[overdub.take] == 1 and not hashes[unchanged.take])
assert(not next(f.reads))
f.poll(5)
overdub.take.data = 'changed CC data'
f.poll(0)
batch = assert(f.poll(0, .21))
assert(#batch.items == 1 and batch.items[1] == overdub and not next(f.reads))

-- If REAPER cannot provide a hash, the MIDI-buffer fallback still works.
f = fixture()
f.api.MIDI_GetHash = function() return false, '' end
overdub = f.item()
f.poll(0); f.poll(5)
overdub.take.data = 'changed MIDI'
f.poll(0)
assert(f.poll(0, .21).items[1] == overdub and f.reads[overdub.take] >= 2)

print('midi_record_watch: all tests passed')
