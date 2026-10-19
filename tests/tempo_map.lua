-- Run: lua tests/tempo_map.lua
-- Actual module, with replacement-mask semantics and checked native writes.
local factory = dofile("lib/tempo_map.lua")
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}; for k, v in pairs(value) do result[k] = copy(v) end; return result
end
local original = {
    { timepos = 0, bpm = 120, timesig_num = 5, timesig_denom = 4, flags = 31, lineartempo = true, beat_basis = 1.5, metronome_pattern = "ABBCC" },
    { timepos = 10, bpm = 140, timesig_num = 4, timesig_denom = 4, flags = 1, lineartempo = false, beat_basis = 0.75 },
    { timepos = 20, bpm = 140, timesig_num = 6, timesig_denom = 4, flags = 11, lineartempo = false, beat_basis = 2, metronome_pattern = "ABBCBB" },
    { timepos = 30, bpm = 150, timesig_num = 4, timesig_denom = 4, flags = 5, lineartempo = true, beat_basis = 1 },
    { timepos = 40, bpm = 160, timesig_num = 0, timesig_denom = 0, flags = 0, lineartempo = false, beat_basis = 0.5 }
}
local function environment(markers)
    local project = { markers = copy(markers or original), bpm = 117, num = 7, denom = 8, mutations = 0 }
    local api = {}
    api.GetAppVersion = function() return "7.75" end
    local function marker_at(time)
        for _, m in ipairs(project.markers) do if math.abs(m.timepos - time) < 1e-7 then return m end end
    end
    api.GetProjectTimeSignature2 = function() return project.bpm, project.num end
    api.SetCurrentBPM = function(_, bpm) assert(#project.markers == 0, "set defaults only without markers"); project.bpm = bpm end
    api.SNM_GetIntConfigVar = function(key) return key == "projtsdenom" and project.denom or project.num end
    api.SNM_SetIntConfigVar = function(key, v)
        if key == "projtsdenom" then project.denom = v else project.num = v end
        return true
    end
    api.CountTempoTimeSigMarkers = function() return #project.markers end
    api.GetTempoTimeSigMarker = function(_, i)
        local m = project.markers[i + 1]
        if not m then return false end
        return true, m.timepos, math.floor(m.timepos / 2), m.timepos % 2,
            m.bpm, m.timesig_num, m.timesig_denom, m.lineartempo
    end
    api.DeleteTempoTimeSigMarker = function(_, i)
        project.mutations = project.mutations + 1
        table.remove(project.markers, i + 1); return true
    end
    api.SetTempoTimeSigMarker = function(_, i, time, measure, beat, bpm, num, denom, linear)
        assert(measure == -1 and beat == -1, "seconds coordinates must not include musical positions")
        project.mutations = project.mutations + 1
        local m = { timepos = time, bpm = bpm, timesig_num = num, timesig_denom = denom,
            lineartempo = linear, flags = num > 0 and 1 or 0, beat_basis = 1 }
        if i == -1 then project.markers[#project.markers + 1] = m else project.markers[i + 1] = m end
        table.sort(project.markers, function(a, b) return a.timepos < b.timepos end)
        return true
    end
    api.GetSetTempoTimeSigMarkerFlag = function(_, i, flags, write)
        local m = assert(project.markers[i + 1]); if write then m.flags = flags end; return m.flags
    end
    api.GetSetTempoTimeSigMarkerBasis = function(_, i, basis, write)
        local m = assert(project.markers[i + 1]); if write then m.beat_basis = basis end; return m.beat_basis
    end
    api.TimeMap_GetMetronomePattern = function(_, time, query)
        local m = assert(marker_at(time))
        if query:sub(1, 4) == "SET:" then m.metronome_pattern = query:sub(5); m.flags = m.flags | 8 end
        return m.timesig_denom, m.metronome_pattern or "ABBB"
    end
    return factory.new(api), project, api
end
local function equal(a, b, label)
    if type(a) ~= "table" then assert(a == b, (label or "state") .. " differs: " .. tostring(a) .. " ~= " .. tostring(b)); return end
    assert(type(b) == "table", label)
    for k, v in pairs(a) do equal(v, b[k], (label or "state") .. "." .. tostring(k)) end
    for k in pairs(b) do assert(a[k] ~= nil, "unexpected field " .. tostring(k)) end
end
local function fails(fn, fragment)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(fragment, 1, true), "expected error containing " .. fragment .. ": " .. tostring(err))
end

local map, project = environment()
local saved = map.capture(0)
local immutable = copy(saved)
map.restore(0, saved)
equal(saved, map.capture(0), "mixed map roundtrip")
map.scale(0, saved, 1.25)
assert(project.bpm == 146.25, "default tempo scales before first point")
for i, m in ipairs(map.capture(0).markers) do
    assert(m.timepos == saved.markers[i].timepos / 1.25 and m.bpm == saved.markers[i].bpm * 1.25)
    assert(m.flags == saved.markers[i].flags and m.beat_basis == saved.markers[i].beat_basis)
    assert(m.metronome_pattern == saved.markers[i].metronome_pattern)
end
map.ensure(0, 16, 175, true)
local overridden = map.capture(0).markers[3]
assert(overridden.flags == 9 and overridden.timesig_num == 6 and overridden.bpm == 175,
    "intentional region-start override keeps meter/options and enables Set tempo")
map.ensure(0, 25, 175, true)
assert(#project.markers == #saved.markers + 1, "temporary marker inserted")
map.restore(0, saved)
equal(saved, map.capture(0), "cleanup removes temporary markers and restores original checkbox")
equal(saved, immutable, "snapshot remains immutable")

map, project = environment({})
saved = map.capture(0)
map.scale(0, saved, 1.5)
assert(#project.markers == 0 and project.bpm == 175.5, "marker-less map scales project BPM")
project.num, project.denom = 4, 4
map.restore(0, saved)
equal(saved, map.capture(0), "zero-marker defaults restored")

for _, fault in ipairs({ "flags missing", "flags invalid", "read failure", "patterns missing", "basis invalid" }) do
    local api
    map, project, api = environment()
    if fault == "flags missing" then api.GetSetTempoTimeSigMarkerFlag = nil
    elseif fault == "flags invalid" then api.GetSetTempoTimeSigMarkerFlag = function() return -1 end
    elseif fault == "read failure" then api.GetTempoTimeSigMarker = function() return false end
    elseif fault == "patterns missing" then api.TimeMap_GetMetronomePattern = nil
    else api.GetSetTempoTimeSigMarkerBasis = function() return nil end end
    fails(function() map.capture(0) end, "Tempo map:")
    assert(project.mutations == 0, fault .. " must abort before mutation")
end

for _, version in ipairs({ "6.68", "7.27", "missing" }) do
    local api
    map, project, api = environment()
    api.GetAppVersion = version ~= "missing" and function() return version end or nil
    fails(function() map.capture(0) end, "7.28")
    assert(project.mutations == 0, "unsupported custom-pattern setter must abort before mutation")
end

local api
map, project, api = environment()
api.GetSetTempoTimeSigMarkerBasis = nil -- Older REAPER has no non-quarter basis API.
api.SNM_GetIntConfigVar, api.SNM_SetIntConfigVar = nil, nil
saved = map.capture(0)
map.scale(0, saved, 1.25)
map.restore(0, saved)
equal(saved, map.capture(0), "native-only metadata roundtrip")
project.num = 4
local writes_before = project.mutations
fails(function() map.restore(0, saved) end, "changed project meter defaults require SWS")
assert(project.mutations == writes_before, "unrestorable changed defaults must abort before deletion")

map, project, api = environment()
saved = map.capture(0)
local invalid = copy(saved); invalid.markers[3].flags = nil
fails(function() map.restore(0, invalid) end, "incomplete snapshot")
assert(project.mutations == 0, "invalid snapshot must not delete anything")
api.DeleteTempoTimeSigMarker = function() return false end
fails(function() map.restore(0, saved) end, "failed to delete")
equal(saved, map.capture(0), "failed deletion leaves map intact")

for _, fault in ipairs({ "insert", "flags", "pattern", "basis" }) do
    map, project, api = environment()
    saved = map.capture(0)
    local restore_api
    if fault == "insert" then
        restore_api = api.SetTempoTimeSigMarker
        api.SetTempoTimeSigMarker = function() return false end
    elseif fault == "flags" then
        restore_api = api.GetSetTempoTimeSigMarkerFlag
        api.GetSetTempoTimeSigMarkerFlag = function(proj, i, flags, write) return restore_api(proj, i, flags, false) end
    elseif fault == "pattern" then
        restore_api = api.TimeMap_GetMetronomePattern
        api.TimeMap_GetMetronomePattern = function(proj, time, query) return restore_api(proj, time, "EXTENDED") end
    else
        restore_api = api.GetSetTempoTimeSigMarkerBasis
        api.GetSetTempoTimeSigMarkerBasis = function(proj, i, basis, write) return restore_api(proj, i, basis, false) end
    end
    fails(function() map.restore(0, saved) end, "Tempo map:")
    if fault == "insert" then api.SetTempoTimeSigMarker = restore_api
    elseif fault == "flags" then api.GetSetTempoTimeSigMarkerFlag = restore_api
    elseif fault == "pattern" then api.TimeMap_GetMetronomePattern = restore_api
    else api.GetSetTempoTimeSigMarkerBasis = restore_api end
    map.restore(0, saved)
    equal(saved, map.capture(0), "cleanup retry after failed " .. fault .. " write")
end

-- Native map APIs use an explicit project; SWS defaults use the active tab.
-- Cleanup must target the original project after a tab switch and always return
-- to the user's current tab, including failed restoration attempts.
map, project, api = environment()
local other = { bpm = 88, num = 3, denom = 16, markers = { { time = 2, bpm = 88 } } }
local other_original = copy(other)
local active = project
api.EnumProjects = function() return active end
api.ValidatePtr = function(pointer, kind) return kind == "ReaProject*" and (pointer == project or pointer == other) end
api.SelectProjectInstance = function(pointer) active = pointer end
api.SNM_GetIntConfigVar = function(key) return key == "projtsdenom" and active.denom or active.num end
api.SNM_SetIntConfigVar = function(key, value)
    if key == "projtsdenom" then active.denom = value else active.num = value end
    return true
end
saved = map.capture(project)
map.scale(project, saved, 1.25)
project.num, project.denom = 4, 4
active = other
map.restore(project, saved)
assert(active == other, "cleanup must reactivate the user's current tab")
equal(other, other_original, "other project's map/defaults stay untouched")
active = project
equal(saved, map.capture(project), "original project's map/defaults restored after tab switch")
active = other
local original_insert = api.SetTempoTimeSigMarker
api.SetTempoTimeSigMarker = function() return false end
fails(function() map.restore(project, saved) end, "failed to insert")
assert(active == other, "failed restoration must also reactivate the user's current tab")
equal(other, other_original, "failed restoration must not modify the other project")
api.SetTempoTimeSigMarker = original_insert
map.restore(project, saved)
assert(active == other, "retry returns to the user's current tab")
print("PASS: mixed tempo/meter maps, patterns, beat bases, defaults, explicit overrides, capture preflight, checked writes and cleanup retries")
