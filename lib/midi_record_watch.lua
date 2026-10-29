-- Observe recording sessions and report completed MIDI items; never mutate REAPER.
local M = {}

local function fingerprint(api, take)
    if api.MIDI_GetHash then
        local ok, hash = api.MIDI_GetHash(take, false, '')
        if ok then return 'hash', hash end
    end
    local ok, data = api.MIDI_GetAllEvts(take, '')
    if ok then return 'events', data end
end

local function snapshot(api, project, tracks)
    local result = {}
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local take = api.GetActiveTake(item)
        local entry = { take = take }
        if tracks[api.GetMediaItemTrack(item)] and take and api.TakeIsMIDI(take) then
            entry.kind, entry.signature = fingerprint(api, take)
        end
        result[item] = entry
    end
    return result
end

local function same_tracks(a, b)
    if not a or not b then return false end
    for track in pairs(a) do if not b[track] then return false end end
    for track in pairs(b) do if not a[track] then return false end end
    return true
end

local function armed_tracks(api, project)
    local tracks = {}
    for i = 0, api.CountTracks(project) - 1 do
        local track = api.GetTrack(project, i)
        if api.GetMediaTrackInfo_Value(track, 'I_RECARM') ~= 0 then tracks[track] = true end
    end
    return tracks
end

local function recorded_items(api, project, session)
    local items = {}
    for i = 0, api.CountMediaItems(project) - 1 do
        local item = api.GetMediaItem(project, i)
        local take = api.GetActiveTake(item)
        if session.tracks[api.GetMediaItemTrack(item)] and take and api.TakeIsMIDI(take) then
            local previous = session.before[item]
            local changed = not previous or previous.take ~= take
            if not changed then
                local kind, signature = fingerprint(api, take)
                changed = kind ~= nil and previous.kind == kind and signature ~= previous.signature
            end
            if changed then items[#items + 1] = item end
        end
    end
    return items
end

-- Call poll() from a defer loop. It returns { project=..., items={...} } once
-- per recording, after transport is fully stopped and REAPER has settled.
-- Enable before recording: enabling midway through a recording ignores that
-- session because its pre-recording MIDI cannot be identified reliably.
function M.new(api, options)
    local settle = (options or {}).settle_seconds or 0.2
    assert(settle >= 0, 'Settle interval must be nonnegative.')
    local project, baseline, baseline_tracks, revision, session, previous_recording, initialized
    local watcher = {}

    function watcher.poll()
        local current = api.EnumProjects(-1, '')
        if current ~= project then
            project, baseline, baseline_tracks, revision, session, previous_recording, initialized =
                current, nil, nil, nil, nil, false, false
        end
        if not project then return nil end
        local state = api.GetPlayStateEx(project)
        local recording = state & 4 ~= 0
        local now = api.time_precise()
        if not initialized then
            initialized = true
            previous_recording = recording
            if recording then return nil end
        end

        if recording then
            if not previous_recording and baseline and not session then
                session = { before = baseline, tracks = armed_tracks(api, project) }
            end
            if session then session.stopped_at = nil end
        elseif session then
            if state == 0 then
                session.stopped_at = session.stopped_at or now
                if now - session.stopped_at >= settle then
                    local items = recorded_items(api, project, session)
                    session = nil
                    baseline_tracks = armed_tracks(api, project)
                    baseline = snapshot(api, project, baseline_tracks)
                    revision = api.GetProjectStateChangeCount and api.GetProjectStateChangeCount(project)
                    previous_recording = false
                    if #items > 0 then return { project = project, items = items } end
                end
            else
                session.stopped_at = nil
            end
        else
            local changed = api.GetProjectStateChangeCount and api.GetProjectStateChangeCount(project)
            local tracks = armed_tracks(api, project)
            -- Arming can be changed by another script without a project revision.
            -- Refresh its MIDI baseline before the next recording starts.
            if not baseline or changed == nil or changed ~= revision or not same_tracks(tracks, baseline_tracks) then
                baseline = snapshot(api, project, tracks)
                baseline_tracks = tracks
                revision = changed
            end
        end
        previous_recording = recording
        return nil
    end

    return watcher
end

return M
