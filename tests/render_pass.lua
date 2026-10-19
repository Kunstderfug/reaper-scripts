-- Run from the repository root: lua tests/render_pass.lua
local render_pass = dofile("lib/render_pass.lua")
local cases = 0

local function fixture(options)
    options = options or {}
    local calls, files = {}, options.files or { ["/out/section_120.wav"] = true }
    local api = {
        GetAppVersion = function() return options.version or "7.84/OSX64" end,
        GetAllProjectPlayStates = function(ignore_project)
            assert(ignore_project == 0)
            return options.play_state or 0
        end,
        file_exists = function(path) return files[path] == true end,
        GetSetProjectInfo_String = function(proj, key, value, is_set)
            assert(proj == "project" and is_set == false)
            calls[#calls + 1] = { key = key, value = value }
            if key == "RENDER_TARGETS" then
                return options.targets_ok ~= false, options.targets or "/out/section_120.wav"
            end
            if key == "RENDER_FORMAT2" then return true, "" end
            assert(key == "RENDER_STATS")
            assert(value == "42230", "Render must run through action-bound stats, not a later stale query")
            if options.render then return options.render(files) end
            return options.stats_ok ~= false, options.stats or "FILE:/out/section_120.wav;PEAK:-1.000000;CLIP:0"
        end,
    }
    return api, calls, files
end

local function check(name, options, expected, reason_pattern)
    local api, calls = fixture(options)
    local ok, reason = render_pass.run(api, "project")
    assert(ok == expected, name .. ": " .. tostring(reason))
    if reason_pattern then assert(reason:find(reason_pattern), name .. ": " .. reason) end
    cases = cases + 1
    return calls
end

check("successful render", {}, true)
check("supported 6.68 minimum", { version = "6.68/x64" }, true)
local old_calls = check("old cancellation contract rejected", { version = "6.67/x64" }, false, "6.68")
assert(#old_calls == 0, "Old versions must fail before rendering")
check("unknown version", { version = "unknown" }, false, "6.68")
check("native cancellation", { stats = "" }, false, "canceled or failed")
check("native failure", { stats_ok = false }, false, "canceled or failed")
check("canceled with partial kept", { render = function(files)
    files["/out/section_120.wav"] = true
    return true, ""
end }, false, "canceled or failed")
check("canceled with existing output", { stats = "", files = { ["/out/section_120.wav"] = true } }, false, "canceled or failed")
check("identical successful overwrite", {
    previous = "FILE:/out/section_120.wav;PEAK:-1;CLIP:0",
    stats = "FILE:/out/section_120.wav;PEAK:-1;CLIP:0",
}, true)
local recording_calls = check("recording rejected before rendering", { play_state = 5 }, false, "Stop recording")
assert(#recording_calls == 0, "Recording must fail before reading targets or rendering")
check("paused transport permitted", { play_state = 2 }, true)
check("new stats for other file", { stats = "FILE:/out/other.wav;PEAK:-1" }, false, "do not match")
check("successful overwrite with fresh stats", {
    previous = "FILE:/out/section_120.wav;PEAK:-2;CLIP:0",
    stats = "FILE:/out/section_120.wav;PEAK:-1;CLIP:0",
}, true)
check("filename stats", { stats = "FILE:section_120.wav;PEAK:-1" }, true)
check("missing file despite stats", { files = {} }, false, "missing")
check("missing FILE confirmation", { stats = "PEAK:-1;CLIP:0" }, false, "every output")
check("native throws", { render = function() error("render exploded") end }, false, "render exploded")
local no_targets = check("empty targets rejected", { targets = "" }, false, "No render output")
assert(#no_targets == 1, "Empty outputs must fail before rendering")
check("separator-only targets rejected", { targets = ";" }, false, "No render output")
check("target lookup failure", { targets_ok = false }, false, "No render output")
check("multiple outputs", {
    targets = "/out/section_120.wav;/out/section_120.mp3",
    stats = "FILE:/out/section_120.wav;PEAK:-1;FILE:/out/section_120.mp3;PEAK:-1",
    files = { ["/out/section_120.wav"] = true, ["/out/section_120.mp3"] = true },
}, true)
check("incomplete outputs", {
    targets = "/out/section_120.wav;/out/section_120.mp3",
}, false, "every output")
check("duplicate stats", {
    stats = "FILE:/out/section_120.wav;PEAK:-1;FILE:/out/section_120.wav;PEAK:-1",
}, false, "do not match")
check("ambiguous filename", {
    targets = "/one/section.wav;/two/section.wav",
    stats = "FILE:section.wav;PEAK:-1;FILE:section.wav;PEAK:-1",
}, false, "do not match")
check("three ambiguous filenames", {
    targets = "/one/section.wav;/two/section.wav;/three/section.wav",
    stats = "FILE:section.wav;PEAK:-1",
}, false, "do not match")
local duplicate_calls = check("duplicate target file", {
    targets = "/out/section_120.wav;/out/section_120.wav",
}, false, "same file")
assert(#duplicate_calls == 1, "Filename collisions must fail before rendering")
local unsupported = fixture()
unsupported.file_exists = nil
local supported, reason = render_pass.preflight(unsupported)
assert(supported == false and reason:find("APIs"))
cases = cases + 1

print(string.format("PASS: %d render completion cases", cases))
