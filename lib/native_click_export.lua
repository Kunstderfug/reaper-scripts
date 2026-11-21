-- Native measure/tempo grid to GPhil {time: milliseconds, beat: one-based} JSON.
-- Does not change the project or synthesize authored fermata/custom-click exceptions.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local protocol = dofile(here .. 'native_bridge_protocol.lua')
function M.projects(api)
    local result = protocol.array()
    local current = api.EnumProjects(-1, '')
    for i = 0, 1000 do
        local p, path = api.EnumProjects(i, '')
        if not p then break end
        result[#result + 1] = {index=i, path=path, current=p == current,
            dirty=api.IsProjectDirty(p) ~= 0, playing=api.GetPlayStateEx(p) ~= 0}
    end
    return result
end
-- Bump when exported events or receipt semantics change.
M.VERSION = 'gphil-native-click-export/2'
local BEAT_EPS = 1e-4 -- denominator beats
local PROBE = 1e-6 -- seconds; reads identity just after the candidate so rounding cannot land in the prior measure
-- Native identity at a timestamp: beat within measure (denominator beats), measure index, numerator, denominator.
local function identity(api, proj, t)
    local beat, measure, cml, _, cdenom = api.TimeMap2_timeToBeats(proj, t + PROBE)
    return beat, measure, cml, cdenom
end
-- Candidates come from TimeMap_GetMeasureInfo (q0 + beat * 4 / denominator), but only REAPER's own
-- TimeMap2_timeToBeats identity decides membership. A candidate that native identity places in a later
-- measure (overflow of a truncated/reset measure) is excluded; if it lands on a whole beat, that later
-- measure must have exported the same beat at the same millisecond. Anything else inconsistent fails.
function M.collect(api, proj, region, grid_only)
    assert(region.finish > region.start, 'Empty region: ' .. region.name)
    local _, first = api.TimeMap2_timeToBeats(proj, region.start)
    local _, last = api.TimeMap2_timeToBeats(proj, region.finish - 1e-8)
    assert(first and last and last >= first and last - first < 100000, 'Region exceeds measure limit')
    local function where(measure, beat) return region.name .. ' measure index ' .. measure .. ' beat ' .. beat end
    local events, overflow, accepted = {}, {}, {}
    for measure = first, last do
        local _, q0, qend, numerator, denominator = api.TimeMap_GetMeasureInfo(proj, measure)
        assert(numerator > 0 and denominator > 0 and qend > q0, 'Invalid native measure')
        for beat = 0, numerator - 1 do
            local q = q0 + beat * 4 / denominator
            if q < qend - 1e-8 then
                local t = api.TimeMap2_QNToTime(proj, q)
                if t >= region.start - 1e-7 and t < region.finish - 1e-7 then
                    local b, owner, cml, cdenom = identity(api, proj, t)
                    assert(owner and owner >= measure and owner <= last,
                        'Native measure identity is inconsistent at ' .. where(measure, beat) .. '; unsupported tempo/meter map')
                    if owner == measure then
                        assert(math.abs(b - beat) <= BEAT_EPS, string.format(
                            'Native beat identity %.6f disagrees with measure grid at %s; unsupported tempo/meter map', b, where(measure, beat)))
                        assert(cml == numerator and cdenom == denominator,
                            'Native meter identity disagrees with measure info at ' .. where(measure, beat))
                        if not grid_only then
                            local _, pattern = api.TimeMap_GetMetronomePattern(proj, t + 1e-9, 'EXTENDED')
                            assert(pattern == 'A' .. string.rep('B', numerator - 1),
                                'Custom click pattern in ' .. region.name .. '; preserve authored clicks or explicitly use --grid-only')
                        end
                        events[#events + 1] = {t=t, measure=measure, beat=beat}
                        accepted[measure .. ':' .. beat] = t
                        assert(#events <= 1000000, 'Click count limit exceeded')
                    else
                        overflow[#overflow + 1] = {t=t, owner=owner, beat=b, measure=measure, from=beat}
                    end
                end
            end
        end
    end
    for _, o in ipairs(overflow) do
        local whole = math.floor(o.beat + 0.5)
        if math.abs(o.beat - whole) <= BEAT_EPS then
            local t = accepted[o.owner .. ':' .. whole]
            assert(t and math.floor(t * 1000 + 0.5) == math.floor(o.t * 1000 + 0.5),
                'Native beat at ' .. where(o.owner, whole) .. ' is missing from its own measure; unsupported partial-measure map')
        end
    end
    table.sort(events, function(a, b) return a.t < b.t end)
    local clicks = protocol.array()
    for i, e in ipairs(events) do
        local ms = math.floor((e.t - region.start) * 1000 + 0.5)
        if i > 1 and ms <= clicks[#clicks].time then
            local prior = events[i - 1]
            error('Click times collide at millisecond precision at ' .. where(e.measure, e.beat) ..
                ' and ' .. where(prior.measure, prior.beat))
        end
        clicks[#clicks + 1] = {time=ms, beat=e.beat + 1}
    end
    assert(#clicks > 0, 'No grid clicks in ' .. region.name)
    return clicks, #overflow
end
local function resolve(api, request)
    if not request.project or request.project == '' then
        local proj, path = api.EnumProjects(-1, '')
        return proj, false, path
    end
    assert(request.project:sub(1, 1) == '/', 'Project must be an absolute path')
    for i = 0, 1000 do
        local p, path = api.EnumProjects(i, '')
        if not p then break end
        if path == request.project then return p, false, path end
    end
    assert(request.open_project == '1', 'Project is not open; use --open-project to inspect its saved file')
    assert(request.project:lower():match('%.rpp$'), 'Expected an RPP project')
    local f = assert(io.open(request.project, 'rb')); f:close()
    api.Main_OnCommand(40859, 0) -- new tab in this instance
    local own = api.EnumProjects(-1, '')
    api.Main_openProject(request.project)
    local p, path = api.EnumProjects(-1, '')
    assert(p == own and path == request.project, 'Could not open requested project in own tab')
    return p, true, path
end
function M.run(api, request)
    assert(request.output and request.output:sub(1, 1) == '/', 'Output must be an absolute directory')
    -- The bridge writes only into a fresh request-owned child directory.
    local output = request.output
    local saved_only = request.saved_only == '1'
    -- Checked before any tab is touched: saved-only must name the exact saved file.
    assert(not saved_only or (request.project and request.project ~= ''), 'Saved-only export requires an explicit --project')
    local previous = api.EnumProjects(-1, '')
    local existing = {}
    for i = 0, 1000 do local p = api.EnumProjects(i, ''); if not p then break end; existing[p] = true end
    local result
    local ok, err = xpcall(function()
        local proj, opened, path = resolve(api, request)
        assert(api.GetPlayStateEx(proj) == 0, 'Stop target project playback/recording before export')
        local dirty_before = api.IsProjectDirty(proj) ~= 0
        local count_before = api.GetProjectStateChangeCount(proj)
        if saved_only then
            assert(path == request.project, 'Saved-only target path mismatch')
            assert(not dirty_before, 'Saved-only export refused: ' .. path .. ' has unsaved changes; save it or omit --saved-only')
        end
        local pending, names = {}, {}
        for i = 0, 100000 do
            local found, isregion, start, finish, name, id = api.EnumProjectMarkers3(proj, i)
            if found == 0 then break end
            if isregion and (not request.region or request.region == '' or name == request.region) then
                assert(name:match('^[%w_%-%. ]+$') and name ~= '.' and name ~= '..', 'Unsafe/empty region filename')
                assert(not names[name:lower()], 'Duplicate region filename: ' .. name); names[name:lower()] = true
                local region = {id=id, name=name, start=start, finish=finish}
                local clicks, excluded = M.collect(api, proj, region, request.grid_only == '1')
                pending[#pending + 1] = {region=region, clicks=clicks, excluded=excluded}
            end
        end
        assert(#pending > 0, 'No matching regions')
        local dirty_after = api.IsProjectDirty(proj) ~= 0
        local count_after = api.GetProjectStateChangeCount(proj)
        if saved_only then
            -- Nothing is written unless the saved tab stayed clean and unchanged throughout collection.
            assert(not dirty_after and count_after == count_before,
                'Saved-only export refused: project state changed during export')
        end
        result = {project=path, source='REAPER native measure/tempo API', gridOnly=request.grid_only == '1',
            savedOnly=saved_only, exporterVersion=M.VERSION, openedOwnTab=opened,
            dirtyBefore=dirty_before, dirtyAfter=dirty_after,
            stateChangeCountBefore=count_before, stateChangeCountAfter=count_after,
            files=protocol.array(), warning='Beat grid only; authored fermata timing and CLICK item overrides are not inferred.'}
        api.RecursiveCreateDirectory(output, 0)
        for _, row in ipairs(pending) do
            local file = output .. '/' .. row.region.name .. '.json'
            local f = io.open(file, 'rb'); if f then f:close(); error('Output already exists: ' .. file) end
        end
        for _, row in ipairs(pending) do
            local file = output .. '/' .. row.region.name .. '.json'
            protocol.write(file, protocol.json(row.clicks) .. '\n')
            result.files[#result.files + 1] = {path=file, region=row.region, events=#row.clicks,
                excludedCandidates=row.excluded}
        end
    end, debug.traceback)
    -- Cleanup covers failures during opening too, and never saves/clears dirty state.
    local created = {}
    for i = 0, 1000 do local p = api.EnumProjects(i, ''); if not p then break end; if not existing[p] then created[#created + 1] = p end end
    local cleanup_error
    for _, p in ipairs(created) do
        if api.IsProjectDirty(p) == 0 then
            api.SelectProjectInstance(p); api.Main_OnCommand(40860, 0)
            if api.ValidatePtr(p, 'ReaProject*') then cleanup_error = 'Own project tab did not close' end
        else cleanup_error = 'Own project tab unexpectedly dirty; left open without saving' end
    end
    if previous and api.ValidatePtr(previous, 'ReaProject*') then api.SelectProjectInstance(previous) end
    -- Report the export failure first; a cleanup problem is appended, never masks it.
    if not ok then error(cleanup_error and (tostring(err) .. '\nCleanup: ' .. cleanup_error) or err, 0) end
    assert(not cleanup_error, cleanup_error)
    return result
end
return M
