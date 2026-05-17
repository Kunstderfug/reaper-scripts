-- Create regions for selected media items using active take names without extension.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper

local function strip_extension(name)
    if not name or name == "" then
        return ""
    end

    local base = name:match("^(.*)%.([^%.]+)$")
    if base and base ~= "" then
        return base
    end
    return name
end

local function main()
    local proj = 0
    local selected_count = reaper.CountSelectedMediaItems(proj)
    if selected_count == 0 then
        reaper.ShowMessageBox("No media items selected.", "Create Regions", 0)
        return
    end

    local entries = {}
    local skipped_count = 0

    reaper.Undo_BeginBlock2(proj)
    reaper.PreventUIRefresh(1)

    for i = 0, selected_count - 1 do
        local item = reaper.GetSelectedMediaItem(proj, i)
        local take = item and reaper.GetActiveTake(item) or nil

        if take then
            local take_name = reaper.GetTakeName(take) or ""
            local base_name = strip_extension(take_name)
            local start_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local end_pos = start_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

            entries[#entries + 1] = {
                index = i,
                base_name = base_name,
                start_pos = start_pos,
                end_pos = end_pos
            }
        else
            skipped_count = skipped_count + 1
        end
    end

    table.sort(entries, function(a, b)
        if a.start_pos == b.start_pos then
            return a.index < b.index
        end
        return a.start_pos < b.start_pos
    end)

    local name_counts = {}
    for i = 1, #entries do
        local e = entries[i]
        local key = e.base_name
        local next_index = (name_counts[key] or 0) + 1
        name_counts[key] = next_index

        local region_name = key
        if next_index > 1 then
            region_name = string.format("%s_%02d", key, next_index)
        end

        reaper.AddProjectMarker2(proj, true, e.start_pos, e.end_pos, region_name, -1, 0)
    end

    local created_count = #entries

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock2(
        proj,
        string.format("Create regions from selected item take names (%d created, %d skipped)", created_count, skipped_count),
        -1
    )
end

main()
