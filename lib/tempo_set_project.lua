-- REAPER project helpers shared by the GFX Tempo Set script and GPhilDeck single re-renders.
-- Moved unchanged from GPhil_tempoSet_render_gfx_direct.lua; the API is passed in.
local plan = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./") .. "tempo_set_plan.lua")
local M = {}

function M.new(reaper)
    local RENDER_NUMERIC_KEYS, RENDER_STRING_KEYS = plan.RENDER_NUMERIC_KEYS, plan.RENDER_STRING_KEYS
    local H = {}

    function H.find_click_track(proj)
        local track_count = reaper.CountTracks(proj)
        for i = 0, track_count - 1 do
            local track = reaper.GetTrack(proj, i)
            local _, name = reaper.GetTrackName(track, "")
            if name and name:lower():find("clicktrack") then
                return track
            end
        end
        return nil
    end

    function H.find_solo_track(proj)
        local track_count = reaper.CountTracks(proj)
        for i = 0, track_count - 1 do
            local track = reaper.GetTrack(proj, i)
            local _, name = reaper.GetTrackName(track, "")
            local normalized = (name or ""):match("^%s*(.-)%s*$"):lower()
            if normalized == "solo" then
                return track
            end
        end
        return nil
    end

    function H.select_only_track(track)
        reaper.Main_OnCommand(40297, 0)
        if track and reaper.ValidatePtr2(0, track, "MediaTrack*") then
            reaper.SetTrackSelected(track, true)
        end
    end

    function H.set_render_pattern(proj, pattern)
        reaper.GetSetProjectInfo_String(proj, "RENDER_PATTERN", pattern or "", true)
    end

    function H.resolve_command(cmd_id)
        if not cmd_id or cmd_id == 0 then
            return nil
        end

        if type(cmd_id) == "string" then
            local command = reaper.NamedCommandLookup(cmd_id)
            if command and command ~= 0 then
                return command
            end
            return nil
        end

        return cmd_id
    end

    function H.get_region_name(proj, region_or_marker)
        local ok, name = reaper.GetSetRegionOrMarkerInfo_String(proj, region_or_marker, "P_NAME", "", false)
        if ok then
            return name or ""
        end
        return ""
    end

    function H.collect_regions_with_handles(proj)
        local regions = {}
        local total = reaper.GetNumRegionsOrMarkers(proj)
        for i = 0, total - 1 do
            local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
            if region_or_marker then
                local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
                if is_region then
                    local pos = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "D_STARTPOS")
                    local rgnend = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "D_ENDPOS")
                    local number = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "I_NUMBER")
                    local selected = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL") > 0.5
                    regions[#regions + 1] = {
                        internal_index = i,
                        marker = region_or_marker,
                        pos = pos,
                        rgnend = rgnend,
                        name = H.get_region_name(proj, region_or_marker),
                        number = number,
                        selected = selected
                    }
                end
            end
        end

        table.sort(regions, function(a, b)
            return a.pos < b.pos
        end)

        return regions
    end

    function H.capture_region_selection(proj)
        local snapshot = {}
        local total = reaper.GetNumRegionsOrMarkers(proj)
        for i = 0, total - 1 do
            local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
            if region_or_marker then
                local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
                if is_region then
                    snapshot[#snapshot + 1] = {
                        internal_index = i,
                        selected = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL") > 0.5
                    }
                end
            end
        end
        return snapshot
    end

    function H.restore_region_selection(proj, snapshot)
        if not snapshot then
            return
        end
        for i = 1, #snapshot do
            local row = snapshot[i]
            local region_or_marker = reaper.GetRegionOrMarker(proj, row.internal_index, "")
            if region_or_marker then
                reaper.SetRegionOrMarkerInfo_Value(
                    proj,
                    region_or_marker,
                    "B_UISEL",
                    row.selected and 1 or 0
                )
            end
        end
    end

    function H.clear_all_region_selection(proj)
        local total = reaper.GetNumRegionsOrMarkers(proj)
        for i = 0, total - 1 do
            local region_or_marker = reaper.GetRegionOrMarker(proj, i, "")
            if region_or_marker then
                local is_region = reaper.GetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_ISREGION") > 0.5
                if is_region then
                    reaper.SetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL", 0)
                end
            end
        end
    end

    function H.select_regions(proj, regions)
        H.clear_all_region_selection(proj)
        for i = 1, #regions do
            local region = regions[i]
            if region and region.internal_index ~= nil then
                local region_or_marker = reaper.GetRegionOrMarker(proj, region.internal_index, "")
                if region_or_marker then
                    reaper.SetRegionOrMarkerInfo_Value(proj, region_or_marker, "B_UISEL", 1)
                end
            end
        end
    end

    function H.capture_render_state(proj)
        local state = {
            numeric = {},
            strings = {}
        }

        for i = 1, #RENDER_NUMERIC_KEYS do
            local key = RENDER_NUMERIC_KEYS[i]
            state.numeric[key] = reaper.GetSetProjectInfo(proj, key, 0, false)
        end

        for i = 1, #RENDER_STRING_KEYS do
            local key = RENDER_STRING_KEYS[i]
            local ok, value = reaper.GetSetProjectInfo_String(proj, key, "", false)
            if ok then
                state.strings[key] = value or ""
            end
        end

        return state
    end

    function H.restore_render_state(proj, state)
        if not state then
            return
        end

        for i = 1, #RENDER_NUMERIC_KEYS do
            local key = RENDER_NUMERIC_KEYS[i]
            if state.numeric[key] ~= nil then
                reaper.GetSetProjectInfo(proj, key, state.numeric[key], true)
            end
        end

        for i = 1, #RENDER_STRING_KEYS do
            local key = RENDER_STRING_KEYS[i]
            if state.strings[key] ~= nil then
                reaper.GetSetProjectInfo_String(proj, key, state.strings[key], true)
            end
        end
    end

    function H.path_is_absolute(path)
        return path and (path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil)
    end

    function H.join_path(left, right)
        if not left or left == "" then
            return right or ""
        end
        if not right or right == "" then
            return left
        end
        if H.path_is_absolute(right) then
            return right
        end
        return left:gsub("[/\\]+$", "") .. "/" .. right:gsub("^[/\\]+", "")
    end

    function H.get_project_directory(proj)
        if reaper.GetProjectPathEx then
            local ok, value = pcall(reaper.GetProjectPathEx, proj, "")
            if ok and value and value ~= "" then
                return value
            end
        end

        if reaper.GetProjectPath then
            local ok, value = pcall(reaper.GetProjectPath, "")
            if ok and value and value ~= "" then
                return value
            end
        end

        return ""
    end

    function H.get_render_directory(proj)
        local ok, render_dir = reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", "", false)
        if not ok or not render_dir or render_dir == "" then
            return H.get_project_directory(proj)
        end

        if H.path_is_absolute(render_dir) then
            return render_dir
        end

        return H.join_path(H.get_project_directory(proj), render_dir)
    end

    return H
end

return M
