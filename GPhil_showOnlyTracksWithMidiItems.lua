-- Show only tracks containing MIDI items in the track panel and mixer.
-- Any MIDI take qualifies, including inactive takes and empty MIDI items.
-- Expand ancestor folders so their collapsed state cannot conceal MIDI tracks.
-- Run again to refresh the filter after adding or removing items; undo restores
-- the previous visibility. The master track is left unchanged.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local function has_midi_item(track)
    for item_index = 0, reaper.CountTrackMediaItems(track) - 1 do
        local item = reaper.GetTrackMediaItem(track, item_index)
        for take_index = 0, reaper.CountTakes(item) - 1 do
            local take = reaper.GetTake(item, take_index)
            if take and reaper.TakeIsMIDI(take) then
                return true
            end
        end
    end
    return false
end

local function main()
    local project = 0
    local changes = {}
    local folders_to_expand = {}
    for track_index = 0, reaper.CountTracks(project) - 1 do
        local track = reaper.GetTrack(project, track_index)
        local visible = has_midi_item(track) and 1 or 0
        if visible == 1 then
            local parent = reaper.GetParentTrack(track)
            while parent do
                if reaper.GetMediaTrackInfo_Value(parent, "I_FOLDERCOMPACT") ~= 0 then
                    folders_to_expand[parent] = true
                end
                parent = reaper.GetParentTrack(parent)
            end
        end
        if reaper.GetMediaTrackInfo_Value(track, "B_SHOWINTCP") ~= visible
            or reaper.GetMediaTrackInfo_Value(track, "B_SHOWINMIXER") ~= visible then
            changes[#changes + 1] = { track = track, visible = visible }
        end
    end

    if #changes == 0 and next(folders_to_expand) == nil then
        reaper.defer(function() end)
        return
    end

    reaper.Undo_BeginBlock2(project)
    reaper.PreventUIRefresh(1)
    for _, change in ipairs(changes) do
        reaper.SetMediaTrackInfo_Value(change.track, "B_SHOWINTCP", change.visible)
        reaper.SetMediaTrackInfo_Value(change.track, "B_SHOWINMIXER", change.visible)
    end
    for folder in pairs(folders_to_expand) do
        reaper.SetMediaTrackInfo_Value(folder, "I_FOLDERCOMPACT", 0)
    end
    reaper.PreventUIRefresh(-1)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock2(project, "Show only tracks with MIDI items", -1)
end

main()
