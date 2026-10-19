-- Completion gate for one synchronous native render. The caller owns restoration.
-- RENDER_STATS can run an action before returning its results:
-- https://www.reaper.fm/sdk/reascript/reascripthelp.html#GetSetProjectInfo_String
-- Since 6.68, canceled renders return no statistics (including kept partial files):
-- https://www.reaper.fm/download-old.php?ver=6x
local M = {}
local RENDER_CURRENT_PROJECT = "42230"

local function split(value)
    local values = {}
    for part in value:gmatch("[^;]+") do
        values[#values + 1] = part
    end
    return values
end

local function filename(path)
    return path:match("[^/\\]+$") or path
end

function M.preflight(reaper)
    if type(reaper.GetSetProjectInfo_String) ~= "function"
        or type(reaper.GetAppVersion) ~= "function"
        or type(reaper.GetAllProjectPlayStates) ~= "function"
        or type(reaper.file_exists) ~= "function" then
        return false, "Render now requires REAPER's render statistics and file APIs."
    end
    local major, minor = reaper.GetAppVersion():match("^(%d+)%.(%d+)")
    major, minor = tonumber(major), tonumber(minor)
    if not major or major < 6 or (major == 6 and minor < 68) then
        return false, "Render now requires REAPER 6.68 or newer for cancellation detection."
    end
    -- Native rendering refuses to start while any tab is recording. Detect it
    -- before mutation, rather than accepting statistics from an earlier render.
    if reaper.GetAllProjectPlayStates(0) & 4 ~= 0 then
        return false, "Stop recording before using Render now."
    end
    return true
end

local function read_primary_targets(reaper, proj, all_targets)
    local format_ok, secondary = reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT2", "", false)
    if not format_ok then error("Could not read the secondary render format.", 0) end
    if secondary == "" then return all_targets end

    -- Native statistics describe each primary render, not its secondary encoding.
    -- Query the primary paths with the secondary format temporarily disabled;
    -- guessing extensions would fail for patterns containing $format.
    local ok, targets = pcall(function()
        local cleared = reaper.GetSetProjectInfo_String(proj, "RENDER_FORMAT2", "", true)
        if not cleared then error("Could not inspect primary render outputs.", 0) end
        local found, paths = reaper.GetSetProjectInfo_String(proj, "RENDER_TARGETS", "", false)
        if not found or type(paths) ~= "string" or paths == "" then
            error("No primary render output files were found.", 0)
        end
        return split(paths)
    end)
    local restored, restore_ok = pcall(reaper.GetSetProjectInfo_String, proj, "RENDER_FORMAT2", secondary, true)
    if not restored or not restore_ok then error("Could not restore the secondary render format.", 0) end
    if not ok then error(targets, 0) end
    return targets
end

local function run_checked(reaper, proj, options)
    local supported, reason = M.preflight(reaper)
    if not supported then return false, reason end

    local targets_ok, target_list = reaper.GetSetProjectInfo_String(proj, "RENDER_TARGETS", "", false)
    if not targets_ok or type(target_list) ~= "string" or target_list == "" then
        return false, "No render output files were found; rendering stopped."
    end
    local targets = split(target_list)
    if #targets == 0 then
        return false, "No render output files were found; rendering stopped."
    end
    local all_expected = {}
    for _, target in ipairs(targets) do
        if all_expected[target] then
            return false, "Several render outputs resolve to the same file; rendering stopped."
        end
        all_expected[target] = true
    end
    local primary_targets = read_primary_targets(reaper, proj, targets)
    if #primary_targets == 0 then return false, "No primary render output files were found." end
    local expected, basenames = {}, {}
    for _, target in ipairs(primary_targets) do
        if not all_expected[target] or expected[target] then
            return false, "Primary render outputs do not match the output plan; rendering stopped."
        end
        expected[target] = true
        local name = filename(target)
        -- FILE may be reported as a filename or a full path by the native renderer.
        -- A filename is accepted only when it identifies exactly one target.
        if basenames[name] ~= nil then
            basenames[name] = false
        else
            basenames[name] = target
        end
    end

    if options.overwrite then
        local remove_file = options.remove_file or os.remove
        for _, target in ipairs(targets) do
            if reaper.file_exists(target) then
                local removed, message = remove_file(target)
                if not removed then
                    return false, "Could not overwrite " .. target .. ": " .. tostring(message)
                end
            end
        end
    end

    -- Run the action and retrieve its statistics in one API call. A separate
    -- empty-action stats query can display a preference prompt when retention
    -- is disabled. This action-bound call enables retention for the render.
    local stats_ok, stats = reaper.GetSetProjectInfo_String(proj, "RENDER_STATS", RENDER_CURRENT_PROJECT, false)
    if not stats_ok or type(stats) ~= "string" or stats == "" then
        return false, "Render canceled or failed; no further tempos were rendered."
    end

    local completed, count = {}, 0
    for _, part in ipairs(split(stats)) do
        local rendered_file = part:match("^FILE:(.*)$")
        if rendered_file then
            local target = expected[rendered_file] and rendered_file or basenames[rendered_file]
            if not target or completed[target] then
                return false, "Render results do not match the expected output files; rendering stopped."
            end
            completed[target], count = true, count + 1
        end
    end
    if count ~= #primary_targets then
        return false, "REAPER did not confirm every output file; no further tempos were rendered."
    end
    for _, target in ipairs(targets) do
        if not reaper.file_exists(target) then
            return false, "A rendered output file is missing; no further tempos were rendered."
        end
    end
    return true
end

function M.run(reaper, proj, options)
    local ok, result, reason = pcall(run_checked, reaper, proj, options or {})
    if not ok then
        return false, "Render failed: " .. tostring(result)
    end
    return result, reason
end

return M
