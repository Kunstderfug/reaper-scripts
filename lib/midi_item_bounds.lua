-- Scope, measure-aware planning, and verified item-edge changes. No MIDI writes.
local M = {}
local EPS = 1e-8
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local region_bounds = dofile(here .. 'midi_region_bounds.lua')

function M.enclose(api, project, start_time, end_time)
    local first = api.TimeMap2_timeToQN(project, start_time)
    local last = api.TimeMap2_timeToQN(project, end_time)
    local _, left, next_left = api.TimeMap_QNToMeasures(project, first)
    if math.abs(first - next_left) < EPS then left = next_left end
    local _, right_start, right = api.TimeMap_QNToMeasures(project, last)
    if math.abs(last - right_start) < EPS then right = right_start end
    return left, right
end

function M.collect(api, project, scope)
    if type(scope) == 'table' then return scope end
    local items = {}
    if scope == 'items' then
        for i = 0, api.CountSelectedMediaItems(project) - 1 do
            items[#items + 1] = api.GetSelectedMediaItem(project, i)
        end
    elseif scope == 'tracks' then
        for i = 0, api.CountSelectedTracks(project) - 1 do
            local track = api.GetSelectedTrack(project, i)
            for j = 0, api.CountTrackMediaItems(track) - 1 do
                items[#items + 1] = api.GetTrackMediaItem(track, j)
            end
        end
    elseif scope == 'project' then
        for i = 0, api.CountMediaItems(project) - 1 do items[#items + 1] = api.GetMediaItem(project, i) end
    else error('Unknown item scope.') end
    return items
end

-- REAPER may relocate the terminal all-notes-off/source-length marker when
-- padding a source. Compare every musical event, including CC, text and SysEx.
local function events(api, take)
    local ok, data = api.MIDI_GetAllEvts(take, '')
    assert(ok, 'Cannot read MIDI events.')
    local result, offset, position = {}, 0, 1
    while position <= #data do
        local delta, flags, message
        delta, flags, message, position = string.unpack('<i4Bs4', data, position)
        offset = offset + delta
        local terminal = position > #data and #message == 3 and message:byte(1) & 240 == 176
            and message:byte(2) == 123 and message:byte(3) == 0
        if #message > 0 and not terminal then
            result[#result + 1] = { flags = flags, message = message,
                time = api.MIDI_GetProjTimeFromPPQPos(take, offset) }
        end
    end
    return result
end

local function same_events(before, after)
    if #before ~= #after then return false end
    for i, event in ipairs(before) do
        local other = after[i]
        if event.flags ~= other.flags or event.message ~= other.message
            or math.abs(event.time - other.time) > 1e-7 then return false end
    end
    return true
end

function M.plan(api, project, scope, mode, options)
    mode = mode or 'both'
    assert(mode == 'both' or mode == 'start' or mode == 'end', 'Unknown edge mode.')
    local plan = { targets = {}, skipped = {}, aligned = 0, midi = 0, eligible = {} }
    local regions = region_bounds.collect(api, project)
    -- Shared sources are excluded: extending a source must not affect another
    -- pool instance, even when that instance is outside the chosen scope.
    local pools, chunks = {}, {}
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local ok, chunk = api.GetItemStateChunk(item, '', false)
        assert(ok, 'Cannot inspect item sources; nothing changed.')
        chunks[item] = chunk
        local seen = {}
        for guid in chunk:gmatch('POOLEDEVTS%s+({[^}]+})') do
            if not seen[guid] then pools[guid] = (pools[guid] or 0) + 1; seen[guid] = true end
        end
    end
    for _, item in ipairs(M.collect(api, project, scope)) do
        local active = api.GetActiveTake(item)
        if active and api.TakeIsMIDI(active) then
            plan.midi = plan.midi + 1
            local reason
            local start = api.GetMediaItemInfo_Value(item, 'D_POSITION')
            local finish = start + api.GetMediaItemInfo_Value(item, 'D_LENGTH')
            local left, right = M.enclose(api, project, start, finish)
            local target = { item = item, left = left, right = right, chunk = chunks[item], takes = {} }
            if api.GetMediaItemInfo_Value(item, 'C_LOCK') & 1 ~= 0 then reason = 'locked item' end
            for guid in target.chunk:gmatch('POOLEDEVTS%s+({[^}]+})') do
                if pools[guid] > 1 then reason = 'shared pooled MIDI' end
            end
            for i = 0, api.CountTakes(item) - 1 do
                local take = api.GetTake(item, i)
                if not api.TakeIsMIDI(take) then reason = 'mixed audio/MIDI takes'; break end
                local source = api.GetMediaItemTake_Source(take)
                if api.GetMediaSourceFileName(source, '') ~= '' then reason = 'external MIDI source'; break end
                local before = events(api, take)
                if api.GetMediaItemInfo_Value(item, 'B_LOOPSRC') ~= 0 then
                    local length, in_qn = api.GetMediaSourceLength(source)
                    local origin = api.MIDI_GetProjQNFromPPQPos(take, 0)
                    local rate = api.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
                    if not in_qn or api.TimeMap2_timeToQN(project, start) < origin - EPS
                        or api.TimeMap2_timeToQN(project, finish) > origin + length / rate + EPS then
                        reason = 'repeating MIDI source'
                    end
                end
                target.takes[#target.takes + 1] = { take = take, before = before }
            end
            -- Add one lead-in bar only when the first visible note is on beat 1.
            -- Base this on note position, not the item edge, to stay idempotent.
            local first_note
            for _, entry in ipairs(target.takes) do
                for _, event in ipairs(entry.before) do
                    if #event.message == 3 and event.message:byte(1) & 240 == 144
                        and event.message:byte(3) > 0 and event.time >= start - EPS
                        and event.time < finish - EPS then
                        first_note = math.min(first_note or event.time, event.time)
                    end
                end
            end
            if first_note and not (options and options.lead_in == false) then
                local qn = api.TimeMap2_timeToQN(project, first_note)
                local _, bar = api.TimeMap_QNToMeasures(project, qn + EPS)
                if math.abs(qn - bar) < 1e-7 then
                    local _, previous = api.TimeMap_QNToMeasures(project, bar - 1e-6)
                    left = math.min(left, math.max(api.TimeMap2_timeToQN(project, 0), previous))
                end
            end
            left, right = region_bounds.limit(api, project, regions, start, finish, left, right, mode)
            if mode == 'end' then left = api.TimeMap2_timeToQN(project, start) end
            if mode == 'start' then right = api.TimeMap2_timeToQN(project, finish) end
            target.left, target.right = left, right
            local new_start = api.TimeMap2_QNToTime(project, left)
            local new_end = api.TimeMap2_QNToTime(project, right)
            for _, entry in ipairs(target.takes) do
                for _, event in ipairs(entry.before) do
                    local status = event.message:byte(1) & 240
                    local note_off = status == 128 or (status == 144 and event.message:byte(3) == 0)
                    if (event.time < start - EPS and event.time >= new_start - EPS)
                        or (not note_off and event.time >= finish - EPS and event.time < new_end - EPS) then
                        reason = 'padding would reveal hidden MIDI events'; break
                    end
                end
            end
            if not reason then plan.eligible[#plan.eligible + 1] = item end
            if math.abs(new_start - start) < EPS and math.abs(new_end - finish) < EPS then
                plan.aligned = plan.aligned + 1
            elseif reason then
                plan.skipped[reason] = (plan.skipped[reason] or 0) + 1
            else plan.targets[#plan.targets + 1] = target end
        end
    end
    return plan
end

function M.apply(api, project, plan)
    if #plan.targets == 0 then return 0 end
    assert(api.EnumProjects(-1, '') == project, 'Project changed; review the scope again.')
    api.Undo_BeginBlock2(project)
    api.PreventUIRefresh(1)
    local touched = {}
    local ok, err = xpcall(function()
        for _, target in ipairs(plan.targets) do
            touched[#touched + 1] = target
            -- A non-repeating item can still have Loop source enabled by default.
            -- Padding must add silence rather than create new loop iterations.
            assert(api.SetMediaItemInfo_Value(target.item, 'B_LOOPSRC', 0), 'Cannot disable source looping.')
            assert(api.MIDI_SetItemExtents(target.item, target.left, target.right), 'Cannot set MIDI item edges.')
            local pos = api.GetMediaItemInfo_Value(target.item, 'D_POSITION')
            local ending = pos + api.GetMediaItemInfo_Value(target.item, 'D_LENGTH')
            assert(math.abs(pos - api.TimeMap2_QNToTime(project, target.left)) < 1e-7
                and math.abs(ending - api.TimeMap2_QNToTime(project, target.right)) < 1e-7,
                'REAPER did not set the requested item edges.')
            for i, entry in ipairs(target.takes) do
                local take = api.GetTake(target.item, i - 1)
                assert(same_events(entry.before, events(api, take)), 'MIDI preservation check failed.')
            end
        end
    end, debug.traceback)
    local restored = true
    if not ok then
        for i = #touched, 1, -1 do
            local target = touched[i]
            if not api.SetItemStateChunk(target.item, target.chunk, false) then restored = false end
        end
    end
    api.PreventUIRefresh(-1)
    api.UpdateArrange()
    api.Undo_EndBlock2(project, 'GPhil: Align MIDI item edges to bars and region limits', -1)
    if not ok then error(tostring(err) .. (restored and '\nOriginal items restored.'
        or '\nRestoration failed. Use Undo to restore original items.'), 0) end
    return #plan.targets
end

function M.summary(plan)
    local lines = { string.format('%d ready / %d already aligned', #plan.targets, plan.aligned) }
    local reasons = {}
    for reason in pairs(plan.skipped) do reasons[#reasons + 1] = reason end
    table.sort(reasons)
    for _, reason in ipairs(reasons) do lines[#lines + 1] = plan.skipped[reason] .. ' skipped: ' .. reason end
    if plan.midi == 0 then lines[#lines + 1] = 'No MIDI items in this scope.' end
    return table.concat(lines, '\n')
end
return M
