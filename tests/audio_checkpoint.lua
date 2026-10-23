-- Run from repository root: lua tests/audio_checkpoint.lua
local checkpoint = dofile("lib/audio_checkpoint.lua")
local project = {}
local function run(options)
    options = options or {}
    local prompts, queries, console = 0, 0, ""
    local api = {
        GetSetProjectInfo_String = function(proj, key, _, set)
            assert(proj == project and key == "RENDER_TARGETS" and not set)
            queries = queries + 1
            return not options.missing_targets, options.missing_targets and "" or "/output/A_160.flac;/output/A_160.ogg"
        end,
        ShowConsoleMsg = function(text) console = console .. text end,
        ShowMessageBox = function(message, title, buttons)
            prompts = prompts + 1
            assert(buttons == 4 and title == "Tempo Set: audio check required")
            assert(message:find("Music group 2", 1, true))
            assert(message:find("AUDIO/$region/$project_$region_160", 1, true))
            assert(console:find("RENDER_TARGETS\t/output/A_160.flac;/output/A_160.ogg", 1, true),
                "all primary/secondary exact outputs available before prompt")
            return options.answer or 6
        end
    }
    local ok, reason = checkpoint.review(api, {
        project = project, kind = options.kind or "music", enabled = options.enabled,
        label = "Music group 2, tempo 160", pattern = "AUDIO/$region/$project_$region_160",
        output_directory = "/output"
    })
    return ok, reason, prompts, queries
end
for _, options in ipairs({ {kind="click"}, {enabled=false} }) do
    local ok, _, prompts, queries = run(options)
    assert(ok and prompts == 0 and queries == 0, "disabled/click passes do not gate or query")
end
local ok, reason, prompts = run()
assert(ok and not reason and prompts == 1, "Yes approves one pass")
for _, answer in ipairs({7, 0, 1, 2}) do
    ok, reason, prompts = run({answer=answer})
    assert(not ok and reason:find("Stopped at the audio quality checkpoint",1,true) and prompts == 1,
        "only explicit Yes can continue")
end
ok, reason, prompts = run({missing_targets=true})
assert(not ok and prompts == 0 and reason:find("exact outputs",1,true), "missing scope fails closed")
print("PASS: audio checkpoint exact output scope, Yes-only continuation, click/disabled bypass, missing-target stop")
