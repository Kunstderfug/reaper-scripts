-- Run from the repository root: lua tests/render_stats_native.lua
-- Native REAPER 7.82/macOS-arm64, disposable project, 2026-10-14:
-- RENDER_TARGETS: .../dual.wav;.../dual.flac
-- RENDER_STATS: FILE:.../dual.wav;LENGTH:0:00.200;PEAK:-12.248247;
--              LUFSMMAX:-18.951055;LUFSSMAX:-27.701593;LUFSI:-21.452517
-- Both files were written; statistics describe only the primary output.
-- Capture: /tmp/gphil-native-render-68532c82/probe.txt (ephemeral).
local render_pass = dofile("lib/render_pass.lua")
local cases, failures = 0, {}
local secondary_format = "Y2FsZhgAAAAIAAAA"

local function fixture(options)
    options = options or {}
    local primary = options.primary or "/out/dual.wav"
    local secondary = options.secondary or "/out/dual.flac"
    local state = { format2 = secondary_format, renders = 0, primary_queries = 0 }
    local files = { [primary] = true, [secondary] = not options.missing_secondary }
    local api = {
        GetAppVersion = function() return "7.82/macOS-arm64" end,
        GetAllProjectPlayStates = function() return 0 end,
        file_exists = function(path) return files[path] == true end,
        GetSetProjectInfo_String = function(proj, key, value, is_set)
            assert(proj == "project")
            if key == "RENDER_FORMAT2" then
                if is_set then state.format2 = value end
                return true, state.format2
            end
            assert(is_set == false)
            if key == "RENDER_TARGETS" then
                if state.format2 ~= "" then return true, primary .. ";" .. secondary end
                state.primary_queries = state.primary_queries + 1
                if options.primary_throws then error("primary targets unavailable") end
                if options.primary_fails then return false, "" end
                return true, primary
            end
            assert(key == "RENDER_STATS" and value == "42230")
            assert(state.format2 == secondary_format, "Secondary format must be restored before render")
            state.renders = state.renders + 1
            return true, "FILE:" .. primary .. ";LENGTH:0:00.200;PEAK:-12.248247;"
                .. "LUFSMMAX:-18.951055;LUFSSMAX:-27.701593;LUFSI:-21.452517"
        end,
    }
    return api, state
end

local function check(name, options, expected, expect_render)
    cases = cases + 1
    local api, state = fixture(options)
    local ok, reason = render_pass.run(api, "project")
    local valid = ok == expected
        and state.format2 == secondary_format
        and state.renders == (expect_render and 1 or 0)
        and state.primary_queries > 0
    if not valid then
        failures[#failures + 1] = string.format("%s: ok=%s, reason=%s, format2=%s, renders=%d, primary queries=%d",
            name, tostring(ok), tostring(reason), state.format2, state.renders, state.primary_queries)
    end
end

check("native dual-format render with primary-only statistics", {}, true, true)
check("secondary output must exist", { missing_secondary = true }, false, true)
check("format wildcard may change directory and filename", {
    primary = "/out/WAV/section_WAV.wav", secondary = "/out/FLAC/section_FLAC.flac",
}, true, true)
check("primary target query exception restores secondary format", { primary_throws = true }, false, false)
check("unsuccessful primary target query restores secondary format", { primary_fails = true }, false, false)

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
print(string.format("PASS: %d native render statistics regressions", cases))
