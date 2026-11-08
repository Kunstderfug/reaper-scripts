-- Native initialization delay and pass submission, after presets are applied.
-- This allows FX to settle; it does not reset MIDI controllers or guarantee
-- clean external-server state. REAPER owns the delay (also in queued projects).
local M = {}
local DELAY_ENABLED = 16 << 16
function M.prepare(api, project)
    local settings = math.floor(api.GetSetProjectInfo(project, "RENDER_SETTINGS", 0, false))
    local previous = api.GetSetProjectInfo(project, "RENDER_DELAY", 0, false)
    local seconds = settings & DELAY_ENABLED ~= 0 and math.max(2, previous) or 2
    api.GetSetProjectInfo(project, "RENDER_DELAY", seconds, true)
    api.GetSetProjectInfo(project, "RENDER_SETTINGS", settings | DELAY_ENABLED, true)
end
function M.new(reaper, proj, options)
    local render_now, queue_options = options.render_now, options.queue_options
    local render_pass, audio_checkpoint = options.render_pass, options.audio_checkpoint
    local require_original_project, stop = options.require_original_project, options.stop
    local log, ADD_TO_QUEUE_CMD = options.log, options.queue_command
    return function(kind, label, pattern)
        require_original_project()
        if kind == "music" then
            M.prepare(reaper, proj)
            log("Instrument initialization delay: " .. reaper.GetSetProjectInfo(proj, "RENDER_DELAY", 0, false) .. " seconds.")
        end
        if render_now then
            local complete, reason = render_pass.run(reaper, proj, {
                overwrite = not queue_options.skip_existing,
                remove_file = options.remove_file
            })
            if not complete then
                stop(reason or "Rendering stopped.")
            end
            require_original_project()
            local _, output_directory = reaper.GetSetProjectInfo_String(proj, "RENDER_FILE", "", false)
            local reviewed, checkpoint_reason = audio_checkpoint.review(reaper, {
                enabled = queue_options.pause_audio_check,
                project = proj,
                kind = kind,
                label = label,
                pattern = pattern,
                output_directory = output_directory
            })
            if not reviewed then
                stop(checkpoint_reason)
            end
        else
            reaper.Main_OnCommand(ADD_TO_QUEUE_CMD, 0)
        end
        require_original_project()
    end
end
return M
