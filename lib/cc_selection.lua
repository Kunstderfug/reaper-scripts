-- Cheap selection snapshots, independent of project dirty-state notifications.
local M = {}
function M.snapshot(api)
    local project = api.EnumProjects(-1, '')
    local items, tracks = {}, {}
    for i=0,api.CountSelectedMediaItems(project)-1 do
        local item=api.GetSelectedMediaItem(project,i)
        local take=api.GetActiveTake(item)
        if take and api.TakeIsMIDI(take) then items[#items+1]=tostring(item)..':'..tostring(take) end
    end
    for i=0,api.CountSelectedTracks(project)-1 do tracks[#tracks+1]=tostring(api.GetSelectedTrack(project,i)) end
    return { project=project, revision=api.GetProjectStateChangeCount(project),
        items=table.concat(items,'|'), tracks=table.concat(tracks,'|'),
        item_count=#items, track_count=#tracks }
end
function M.same(a,b)
    return a and b and a.project==b.project and a.revision==b.revision and a.items==b.items and a.tracks==b.tracks
end
function M.resolve(current, previous, scope)
    if previous and current.project==previous.project then
        if current.items~=previous.items and current.item_count>0 then return 'items' end
        if current.tracks~=previous.tracks and current.track_count>0 then return 'tracks' end
        if scope=='items' and current.item_count>0 then return 'items' end
        if scope=='tracks' and current.track_count>0 then return 'tracks' end
    end
    return current.item_count>0 and 'items' or current.track_count>0 and 'tracks' or 'items'
end
return M
