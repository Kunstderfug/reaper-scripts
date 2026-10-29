-- Region limits and nearby overhang trimming; regions may fall between bars.
local M = {}
local EPS = 1e-7 -- Seconds: tolerate arithmetic noise, not recording latency.

function M.collect(api, project)
    local regions = {}
    local count = api.CountProjectMarkers(project)
    for i = 0, count - 1 do
        local found, is_region, first, last = api.EnumProjectMarkers3(project, i)
        assert(found ~= 0, 'Cannot inspect project regions; nothing changed.')
        if is_region and last > first then
            regions[#regions + 1] = { first = first, last = last }
        end
    end
    return regions
end

local function boundary_bar(api, project, time)
    local qn = api.TimeMap2_timeToQN(project, time)
    local _, first = api.TimeMap_QNToMeasures(project, qn - 1e-8)
    local _, _, last = api.TimeMap_QNToMeasures(project, qn + 1e-8)
    return api.TimeMap2_QNToTime(project, first), api.TimeMap2_QNToTime(project, last)
end

local function crosses_other_region(regions, region, edge, is_end)
    for _, other in ipairs(regions) do
        if is_end then
            if other.first >= region.last - EPS and other.first < edge - EPS
                and other.last > region.last + EPS then return true end
        elseif other.last <= region.first + EPS and other.last > edge + EPS
            and other.first < region.first - EPS then return true end
    end
    return false
end

local function limit_once(api, project, regions, start, finish, left, right)
    local first = api.TimeMap2_QNToTime(project, left)
    local last = api.TimeMap2_QNToTime(project, right)
    if start >= 0 then first = math.max(0, first) end
    for _, region in ipairs(regions) do
        -- Associate an overhanging item with a region only when most of the
        -- item lies inside it and both overhangs fit in its boundary bars.
        -- This also repairs a previous run that rounded out to those bars.
        local overlap = math.min(finish, region.last) - math.max(start, region.first)
        if overlap > (finish - start) / 2 then
            local outer_start = boundary_bar(api, project, region.first)
            local _, outer_end = boundary_bar(api, project, region.last)
            if start >= outer_start - EPS and finish <= outer_end + EPS then
                if start < region.first - EPS and not crosses_other_region(regions, region, start, false) then
                    first = math.max(first, region.first)
                end
                if finish > region.last + EPS and not crosses_other_region(regions, region, finish, true) then
                    last = math.min(last, region.last)
                end
            end
        end
        -- Resolve each edge independently. For overlapping/nested regions the
        -- nearest containing boundary wins, independent of enumeration order.
        if region.first <= start + EPS and region.last > start + EPS
            and region.first > first then first = region.first end
        if region.last >= finish - EPS and region.first < finish - EPS
            and region.last < last then last = region.last end
    end
    return api.TimeMap2_timeToQN(project, first), api.TimeMap2_timeToQN(project, last)
end

function M.limit(api, project, regions, start, finish, left, right, mode)
    local original_start, original_end = start, finish
    -- Resolve all consequences before mutating REAPER: initial bar padding can
    -- itself make a nearby region the item's main region. Later iterations
    -- only narrow the candidate, so finite region boundaries guarantee a fixed
    -- point rather than further changes on a second user invocation.
    for _ = 1, #regions * 2 + 3 do
        local a, b = limit_once(api, project, regions, start, finish, left, right)
        if mode == 'end' then a = api.TimeMap2_timeToQN(project, original_start) end
        if mode == 'start' then b = api.TimeMap2_timeToQN(project, original_end) end
        local first, last = api.TimeMap2_QNToTime(project, a), api.TimeMap2_QNToTime(project, b)
        if math.abs(first - start) < 1e-10 and math.abs(last - finish) < 1e-10 then return a, b end
        start, finish, left, right = first, last, a, b
    end
    error('Region edge planning did not converge; nothing changed.')
end

return M
