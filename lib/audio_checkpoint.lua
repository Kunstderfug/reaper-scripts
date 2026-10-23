-- Manual hand-off after a successful native music pass. External analysis owns
-- the audio verdict; this module only prevents the next pass until reviewed.
local M = {}

function M.review(reaper, context)
    if context.enabled == false or context.kind ~= "music" then return true end
    local found, targets = reaper.GetSetProjectInfo_String(context.project, "RENDER_TARGETS", "", false)
    if not found or type(targets) ~= "string" or targets == "" then
        return false, "Could not identify exact outputs for the audio quality checkpoint; rendering stopped."
    end
    -- Native targets include all selected regions and both output formats. Keep
    -- these machine-readable lines in the console while current pass settings
    -- are still active, so an external agent can freeze the exact scan scope.
    reaper.ShowConsoleMsg("TEMPO_SET_AUDIO_CHECK_BEGIN\n"
        .. "PASS\t" .. tostring(context.label) .. "\n"
        .. "PATTERN\t" .. tostring(context.pattern) .. "\n"
        .. "RENDER_TARGETS\t" .. targets .. "\n"
        .. "TEMPO_SET_AUDIO_CHECK_END\n")
    local answer = reaper.ShowMessageBox(
        "Native music render completed. Check the rendered audio externally before continuing."
            .. "\n\nPass: " .. tostring(context.label)
            .. "\nOutput directory: " .. tostring(context.output_directory)
            .. "\nOutput pattern: " .. tostring(context.pattern)
            .. "\n\nYes = audio checked; continue (or finish after the final pass)"
            .. "\nNo = stop and restore original project state"
            .. "\n\nIf distortion is found, choose No and recover before rendering again.",
        "Tempo Set: audio check required", 4)
    if answer ~= 6 then
        return false, "Stopped at the audio quality checkpoint after " .. tostring(context.label)
            .. ". Rendered files were kept; inspect/recover before resuming."
    end
    return true
end

return M
