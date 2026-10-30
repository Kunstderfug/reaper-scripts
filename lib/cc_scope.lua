-- Scope enumeration and pooled/external MIDI preflight; no mutations.
local M = {}
function M.detect_ccs(targets)
    local used = {}
    for _, target in ipairs(targets) do
        local pos = 1
        while pos <= #target.before do
            local _, _, message
            _, _, message, pos = string.unpack('<i4Bs4', target.before, pos)
            if #message == 3 and message:byte(1) & 240 == 176 then used[message:byte(2)] = true end
        end
    end
    local eligible, excluded = {}, {}
    for cc = 0, 127 do
        if used[cc] then
            local continuous = cc >= 1 and cc < 120 and cc ~= 6
                and not (cc >= 32 and cc <= 69) and not (cc >= 96 and cc <= 101)
            local list = continuous and eligible or excluded
            list[#list + 1] = tostring(cc)
        end
    end
    return table.concat(eligible, ','), table.concat(excluded, ',')
end
function M.collect(api, project, scope, items)
    local chosen = {}
    if items then
        assert(scope == 'items', 'Explicit items require item scope.')
        for _, item in ipairs(items) do chosen[item] = true end
    elseif scope == 'items' then
        for i = 0, api.CountSelectedMediaItems(project) - 1 do chosen[api.GetSelectedMediaItem(project, i)] = true end
    elseif scope == 'tracks' then
        for i = 0, api.CountSelectedTracks(project) - 1 do
            local track = api.GetSelectedTrack(project, i)
            for j = 0, api.CountTrackMediaItems(track) - 1 do chosen[api.GetTrackMediaItem(track, j)] = true end
        end
    elseif scope == 'project' then
        for i = 0, api.CountMediaItems(project) - 1 do chosen[api.GetMediaItem(project, i)] = true end
    else error('Scope must be items, tracks, or project.') end
    local entries = {}
    for item in pairs(chosen) do
        local take = api.GetActiveTake(item)
        if take and api.TakeIsMIDI(take) then entries[#entries + 1] = { item=item, take=take } end
    end
    return M.from_takes(api, project, entries)
end
function M.from_takes(api, project, entries)
    local targets, wanted, pools = {}, {}, {}
    local function key(take)
        if api.BR_GetMidiTakePoolGUID then
            local ok, guid = api.BR_GetMidiTakePoolGUID(take)
            if ok and guid ~= '' then return guid end
        end
        return tostring(api.GetMediaItemTake_Source(take))
    end
    -- Pooled sources can have different source pointers. Without SWS use the
    -- source pool GUID from a single-take item's native chunk.
    local function pool(take, item)
        if api.BR_GetMidiTakePoolGUID then return key(take) end
        local ok, chunk = api.GetItemStateChunk(item, '', false)
        assert(ok, 'Cannot inspect MIDI pooling.')
        assert(api.CountTakes(item) == 1, 'Multiple-take MIDI requires SWS for safe pool inspection.')
        return chunk:match('POOLEDEVTS%s+({[^}]+})') or key(take)
    end
    for _, entry in ipairs(entries) do
        local item, take = entry.item, entry.take
        if take and api.TakeIsMIDI(take) then
            local filename = api.GetMediaSourceFileName(api.GetMediaItemTake_Source(take), '')
            assert(filename == '', 'File-backed MIDI must be converted to in-project MIDI before optimization.')
            local id = pool(take, item)
            wanted[take] = true
            if not pools[id] then
                pools[id] = true
                targets[#targets + 1] = { take = take, item = item, pool = id }
            end
        end
    end
    assert(#targets > 0, 'No active MIDI takes in the chosen scope. Select MIDI items or tracks first.')
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        -- Inspect every pool GUID in the item's chunk, rather than requiring
        -- each unrelated item to be single-take when SWS is unavailable.
        if not api.BR_GetMidiTakePoolGUID then
            local ok, chunk = api.GetItemStateChunk(item, '', false)
            assert(ok, 'Cannot inspect MIDI pooling.')
            local outside = false
            for j = 0, api.CountTakes(item) - 1 do
                local take = api.GetTake(item, j)
                if api.TakeIsMIDI(take) and not wanted[take] then outside = true end
            end
            if outside then
                for guid in chunk:gmatch('POOLEDEVTS%s+({[^}]+})') do
                    assert(not pools[guid], 'A selected MIDI pool is shared outside the scope (possibly an inactive take). Unpool that item first; nothing has changed.')
                end
            end
        end
        for j = 0, api.CountTakes(item) - 1 do
            local take = api.GetTake(item, j)
            if api.TakeIsMIDI(take) and not wanted[take] then
                assert(not pools[key(take)], 'A selected MIDI pool is shared outside the scope (possibly an inactive take). Unpool that item first; nothing has changed.')
            end
        end
    end
    for _, target in ipairs(targets) do
        local ok, data = api.MIDI_GetAllEvts(target.take, '')
        assert(ok, 'Could not read MIDI data.')
        local qn = api.MIDI_GetProjQNFromPPQPos(target.take, 0)
        local ppq = api.MIDI_GetPPQPosFromProjQN(target.take, qn + 1) - api.MIDI_GetPPQPosFromProjQN(target.take, qn)
        assert(ppq > 0 and math.abs(ppq - math.floor(ppq + .5)) < .001, 'Unsupported source PPQ.')
        target.ppq, target.before = math.floor(ppq + .5), data
    end
    return targets
end
return M
