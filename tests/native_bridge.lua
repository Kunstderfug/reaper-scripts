local protocol = dofile('lib/native_bridge_protocol.lua')
local exporter = dofile('lib/native_click_export.lua')
-- Piecewise native map fixture. measures[i] = {q0, qend, num, den} (index i-1 in REAPER terms).
-- opts.nominal_end makes TimeMap_GetMeasureInfo report the un-truncated measure end (the O5 overflow case).
local function grid(measures, opts)
    opts = opts or {}
    local scale = opts.scale or 0.4
    local function to_time(q) return opts.ramp and q * q or q * scale end
    local function to_q(t) return opts.ramp and math.sqrt(t) or t / scale end
    local function owner(q)
        for i = #measures, 1, -1 do if q >= measures[i].q0 - 1e-12 then return i end end
        error('fixture underflow')
    end
    local identity_den = opts.identity_den
    return {
        TimeMap2_timeToBeats = function(_, t)
            local q = to_q(t); local i = owner(q); local m = measures[i]
            return (q - m.q0) / (4 / m.den), i - 1, m.num, q, identity_den or m.den
        end,
        TimeMap_GetMeasureInfo = function(_, index)
            local m = assert(measures[index + 1], 'fixture measure')
            local qend = opts.nominal_end and m.q0 + m.num * 4 / m.den or m.qend
            return to_time(m.q0), m.q0 + (opts.q0_shift or 0), qend, m.num, m.den, 120
        end,
        TimeMap2_QNToTime = function(_, q) return to_time(q) end,
        TimeMap_GetMetronomePattern = function(_, t)
            local m = measures[owner(to_q(t))]
            return m.den, 'A' .. string.rep('B', m.num - 1)
        end,
    }
end
-- Regular meter list, optionally appended to an existing list.
local function regular(num, den, count, list)
    list = list or {}
    local q = #list > 0 and list[#list].qend or 0
    for _ = 1, count do
        list[#list + 1] = {q0=q, qend=q + num * 4 / den, num=num, den=den}
        q = list[#list].qend
    end
    return list
end
local function collect(api, start, finish, grid_only)
    return exporter.collect(api, 0, {start=start, finish=finish, name='EP_2'}, grid_only)
end
local function fails(pattern, f, ...)
    local ok, err = pcall(f, ...)
    assert(not ok, 'expected failure: ' .. pattern)
    assert(tostring(err):find(pattern, 1, true), tostring(err))
end
local function beats(clicks)
    local out = {}
    for i, c in ipairs(clicks) do out[i] = c.beat end
    return table.concat(out, ',')
end
local function times(clicks)
    local out = {}
    for i, c in ipairs(clicks) do out[i] = c.time end
    return table.concat(out, ',')
end

-- Ordinary pickup: region starts on beat 2 of 2/4.
local clicks = collect(grid(regular(2, 4, 40)), 0.4, 25.60000001)
assert(#clicks == 63 and clicks[1].time == 0 and clicks[1].beat == 2)
assert(clicks[63].time == 24800 and clicks[63].beat == 2)
-- Compound meters export denominator beats (eighths in 6/8), including pickup phase.
clicks = collect(grid(regular(6, 8, 4)), 0.2, 1.4)
assert(#clicks == 6 and clicks[1].beat == 2 and clicks[6].beat == 1 and clicks[2].time == 200)
-- Nonlinear native time transform; do not flatten ramps to the starting BPM.
clicks = collect(grid(regular(2, 4, 4), {ramp=true}), 1, 9)
assert(#clicks == 2 and clicks[1].time == 0 and clicks[2].time == 3000)
-- Exact end-exclusive bound: a beat exactly at the region end is not exported; one at the start is.
clicks = collect(grid(regular(4, 4, 2)), 0.4, 1.2)
assert(times(clicks) == '0,400' and beats(clicks) == '2,3')

-- O5: truncated 4/4 measure (2 beats) followed by a reset 4/4 measure.
local truncated = regular(4, 4, 1)
truncated[2] = {q0=4, qend=6, num=4, den=4}
regular(4, 4, 2, truncated)
local expected = '1,2,3,4,1,2,1,2,3,4,1,2,3,4'
local exact, n0 = collect(grid(truncated), 0, 5.6)
assert(beats(exact) == expected and n0 == 0)
-- Same map, but measure info reports the nominal 4-beat end: overflow candidates at q=6,7 are owned by
-- the next measure natively, so they are excluded (and cross-checked), never exported twice or relabelled.
local overflowed, n1 = collect(grid(truncated, {nominal_end=true}), 0, 5.6)
assert(beats(overflowed) == expected and times(overflowed) == times(exact) and n1 == 2)
-- Truncated 4/4 followed by 6/8 starting off the quarter grid: overflow candidates fall between native beats.
local reset = regular(4, 4, 1)
reset[2] = {q0=4, qend=5.25, num=4, den=4}
reset[3] = {q0=5.25, qend=8.25, num=6, den=8}
clicks, n1 = collect(grid(reset, {nominal_end=true}), 0, 3.3)
assert(beats(clicks) == '1,2,3,4,1,2,1,2,3,4,5,6' and n1 == 2)
assert(times(clicks) == '0,400,800,1200,1600,2000,2100,2300,2500,2700,2900,3100')
-- Overflow landing on a whole native beat that its own measure did not export is an unsupported map.
local missing = regular(4, 4, 1)
missing[2] = {q0=4, qend=6, num=4, den=4}
missing[3] = {q0=6, qend=10, num=4, den=4}
local api = grid(missing, {nominal_end=true})
local info = api.TimeMap_GetMeasureInfo
api.TimeMap_GetMeasureInfo = function(p, index)
    local t, q0, qend, num, den, bpm = info(p, index)
    if index == 2 then return t, q0 + 1, qend, num, den, bpm end -- shifted grid disagrees with identity
    return t, q0, qend, num, den, bpm
end
fails('unsupported', collect, api, 0, 3.9)
-- Measure grid disagreeing with native beat identity inside a measure fails closed.
fails('Native beat identity', collect, grid(regular(4, 4, 2), {q0_shift=0.5}), 0, 3)
-- Native denominator disagreeing with measure info fails closed.
fails('meter identity', collect, grid(regular(6, 8, 2), {identity_den=4}), 0, 1)
-- True millisecond collisions are rejected, not deduplicated: a partial-measure reset placed 0.4 ms
-- after a beat yields two distinct native beats in the same millisecond.
local near = regular(4, 4, 1)
near[2] = {q0=4, qend=5.001, num=4, den=4}
regular(4, 4, 1, near)
fails('collide at millisecond', collect, grid(near), 0, 3)

-- Custom metronome patterns fail unless --grid-only.
api = grid(regular(4, 4, 2))
api.TimeMap_GetMetronomePattern = function() return 4, 'AB.B' end
fails('Custom click pattern', collect, api, 0, 1.6)
assert(#collect(api, 0, 1.6, true) == 4)
fails('Empty region', collect, grid(regular(2, 4, 2)), 1, 1)

local request = protocol.parse('version=1\ncommand=ping\nregion=Some%20name%25\n')
assert(request.region == 'Some name%')
assert(not pcall(protocol.parse, 'version=1\ncommand=ping\ncommand=stop\n'))
assert(not pcall(protocol.parse, 'version=1\ncommand=%ZZ\n'))
assert(protocol.json(protocol.array()) == '[]')
assert(protocol.json({x='a\nb"'}) == '{"x":"a\\u000ab\\u0022"}')

-- run(): tab safety and saved-only receipts against a mock project list.
local out = os.tmpname(); os.remove(out)
assert(os.execute("mkdir -p '" .. out .. "'"))
local function project_api(tabs, opts)
    opts = opts or {}
    local a = grid(regular(4, 4, 4))
    local current = tabs[1]
    local log = {selected={}, commands={}}
    a.EnumProjects = function(i)
        local tab = i == -1 and current or tabs[i + 1]
        if tab then return tab, tab.path end
    end
    a.ValidatePtr = function(p) for _, t in ipairs(tabs) do if t == p then return true end end return false end
    a.SelectProjectInstance = function(p) current = p; log.selected[#log.selected + 1] = p end
    a.IsProjectDirty = function(p) return p.dirty and 1 or 0 end
    a.GetProjectStateChangeCount = function(p) return p.count end
    a.GetPlayStateEx = function() return 0 end
    a.RecursiveCreateDirectory = function(dir) assert(os.execute("mkdir -p '" .. dir .. "'")) end
    a.EnumProjectMarkers3 = function(p, i)
        if i == 0 then return 1, true, 0, 1.6, opts.region or 'EP_2', 1 end
        return 0
    end
    a.Main_OnCommand = function(cmd)
        log.commands[#log.commands + 1] = cmd
        if cmd == 40859 then
            tabs[#tabs + 1] = {path='', count=0}; current = tabs[#tabs]
        elseif cmd == 40860 then
            assert(not current.dirty, 'closed a dirty tab')
            for i, t in ipairs(tabs) do if t == current then table.remove(tabs, i) break end end
        end
    end
    a.Main_openProject = function(path) current.path = path; current.dirty = opts.open_dirty end
    if opts.mutate then -- simulate a state change while the grid is read
        local q = a.TimeMap2_QNToTime
        a.TimeMap2_QNToTime = function(p, v) opts.mutate(); return q(p, v) end
    end
    return a, log, tabs
end
local n = 0
local function dir() n = n + 1; return out .. '/' .. n end
local function exists(path) local f = io.open(path, 'rb'); if f then f:close() end; return f ~= nil end

-- Missing explicit permission to open a saved project must not change any tabs.
local user = {path='/existing.RPP', count=7}
api, log = project_api({user})
api.Main_OnCommand = function() error('Must not open a tab') end
fails('Project is not open', exporter.run, api, {project='/missing.RPP', output=dir()})
assert(#log.selected == 1 and log.selected[1] == user) -- restores only the original selection

-- Saved-only requires an explicit project and refuses before touching tabs.
api, log = project_api({user})
fails('requires an explicit', exporter.run, api, {saved_only='1', output=dir()})
assert(#log.selected == 0 and #log.commands == 0)

-- Saved-only refuses a dirty exact tab (also with --open-project) and never closes it or writes output.
local dirty = {path='/song.RPP', count=3, dirty=true}
for _, open_project in ipairs({'0', '1'}) do
    local tabs
    api, log, tabs = project_api({user, dirty})
    local target = dir()
    fails('unsaved changes', exporter.run, api,
        {saved_only='1', project='/song.RPP', open_project=open_project, output=target})
    assert(#log.commands == 0 and #tabs == 2 and not exists(target .. '/EP_2.json'))
end

-- Default (no flag) keeps live behaviour: a dirty live tab exports and the receipt says so.
api = project_api({dirty})
local result = exporter.run(api, {output=dir()})
assert(not result.savedOnly and result.dirtyBefore and result.dirtyAfter and result.project == '/song.RPP')
assert(result.exporterVersion == exporter.VERSION and result.files[1].events == 4)

-- Saved-only clean exact tab: receipt carries exact path, dirty flags, state counts, mode and version.
local clean = {path='/song.RPP', count=11}
api, log = project_api({user, clean})
local target = dir()
result = exporter.run(api, {saved_only='1', project='/song.RPP', output=target})
assert(result.savedOnly == true and result.project == '/song.RPP' and result.openedOwnTab == false)
assert(result.dirtyBefore == false and result.dirtyAfter == false)
assert(result.stateChangeCountBefore == 11 and result.stateChangeCountAfter == 11)
assert(result.exporterVersion == 'gphil-native-click-export/2' and exists(target .. '/EP_2.json'))
assert(result.files[1].excludedCandidates == 0)
assert(#log.commands == 0 and #log.selected == 1 and log.selected[1] == user)

-- State change or dirtying during export rejects saved-only with no output.
for _, mutate in ipairs({function() clean.count = clean.count + 1 end, function() clean.dirty = true end}) do
    clean.count, clean.dirty = 11, nil
    api = project_api({user, clean}, {mutate=mutate})
    target = dir()
    fails('state changed during export', exporter.run, api, {saved_only='1', project='/song.RPP', output=target})
    assert(not exists(target .. '/EP_2.json'))
end

local saved = out .. '/other.RPP'
protocol.write(saved, '<REAPER_PROJECT\n>\n')
-- Saved-only via own tab: the clean own tab is closed on success and on failure; the user's dirty tab stays.
for _, region in ipairs({'EP_2', 'BAD/NAME'}) do
    local tabs
    api, log, tabs = project_api({dirty}, {region=region})
    target = dir()
    local ok, res = pcall(exporter.run, api, {saved_only='1', project=saved, open_project='1', output=target})
    if region == 'EP_2' then assert(ok and res.openedOwnTab and res.savedOnly, tostring(res))
    else assert(not ok and tostring(res):find('Unsafe', 1, true), tostring(res)) end
    assert(#tabs == 1 and tabs[1] == dirty and log.selected[#log.selected] == dirty)
end
-- A freshly opened own tab that comes up dirty is refused and left open (never discarded).
local user_tabs
api, log, user_tabs = project_api({user}, {open_dirty=true})
fails('unsaved changes', exporter.run, api, {saved_only='1', project=saved, open_project='1', output=dir()})
assert(#user_tabs == 2 and log.selected[#log.selected] == user)
os.execute("rm -rf '" .. out .. "'")
print('PASS: pickups, denominator beats, nonlinear tempo, end-exclusive bound, truncated/reset measure identity, ' ..
    'collision and ambiguous-map refusal, custom pattern refusal, request validation, tab preservation, saved-only receipts')
