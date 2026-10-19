-- Run from the repository root: lua tests/render_overwrite.lua
local render_pass = dofile("lib/render_pass.lua")
local cases = 0

local primary = "/out/section_120.wav"
local secondary = "/out/section_120.mp3"
local sibling = "/out/section_110.wav"

local function fixture(settings)
    settings = settings or {}
    local state = {
        files = { [primary] = true, [secondary] = true, [sibling] = true },
        removed = {},
        events = {},
        render_count = 0,
        secondary_format = settings.secondary_format or "",
    }
    local targets = settings.targets or { primary }
    local api = {
        GetAppVersion = function() return "7.84/OSX64" end,
        GetAllProjectPlayStates = function() return 0 end,
        file_exists = function(path) return state.files[path] == true end,
        GetSetProjectInfo_String = function(proj, key, value, is_set)
            assert(proj == "project")
            state.events[#state.events + 1] = key
            if key == "RENDER_TARGETS" then
                assert(is_set == false)
                if settings.secondary_format and state.secondary_format == "" then
                    return true, primary
                end
                return true, table.concat(targets, ";")
            elseif key == "RENDER_FORMAT2" then
                if is_set then state.secondary_format = value end
                return true, state.secondary_format
            end
            assert(key == "RENDER_STATS" and value == "42230" and is_set == false)
            assert(state.secondary_format == (settings.secondary_format or ""), "Secondary format was not restored before rendering")
            state.render_count = state.render_count + 1
            if settings.overwrite then
                for _, target in ipairs(targets) do
                    assert(not state.files[target], "Render began before removing an exact existing target: " .. target)
                end
            end
            assert(state.files[sibling], "An unrelated output was removed")
            for _, target in ipairs(targets) do
                if target ~= settings.missing_output then state.files[target] = true end
            end
            if settings.cancel then return true, "" end
            local stats = {}
            local stats_targets = settings.secondary_format and { primary } or targets
            for _, target in ipairs(stats_targets) do
                stats[#stats + 1] = "FILE:" .. target .. ";LENGTH:1.000000;PEAK:-1.000000;CLIP:0"
            end
            return true, table.concat(stats, ";")
        end,
    }
    local options = {
        overwrite = settings.overwrite == true,
        remove_file = function(path)
            assert(state.render_count == 0, "Existing output removal occurred after rendering began")
            assert(state.secondary_format == (settings.secondary_format or ""), "Output deletion occurred before secondary format restoration")
            assert(path == primary or path == secondary, "Removal escaped the current target list")
            assert(state.files[path], "A nonexistent file was removed")
            state.events[#state.events + 1] = "remove:" .. path
            state.removed[#state.removed + 1] = path
            if settings.remove_failure == path then return nil, "Permission denied" end
            state.files[path] = nil
            return true
        end,
    }
    return api, options, state
end

local function run_case(name, settings, expected)
    local api, options, state = fixture(settings)
    local ok, reason = render_pass.run(api, "project", options)
    assert(ok == expected, name .. ": " .. tostring(reason))
    assert(state.files[sibling], name .. ": unrelated sibling output changed")
    assert(state.secondary_format == (settings.secondary_format or ""), name .. ": secondary format changed")
    cases = cases + 1
    return state, reason
end

local single = run_case("overwrite one exact target", { overwrite = true }, true)
assert(#single.removed == 1 and single.removed[1] == primary)
assert(single.files[secondary], "An output format outside this pass was removed")
assert(single.render_count == 1)
assert(single.events[#single.events - 1] == "remove:" .. primary)
assert(single.events[#single.events] == "RENDER_STATS", "Removal must immediately precede rendering")

local both = run_case("overwrite primary and secondary targets", {
    overwrite = true,
    targets = { primary, secondary },
    secondary_format = "bDNwbQ==",
}, true)
assert(#both.removed == 2 and both.removed[1] == primary and both.removed[2] == secondary)
assert(both.render_count == 1 and both.files[primary] and both.files[secondary])
assert(both.events[#both.events - 2] == "remove:" .. primary)
assert(both.events[#both.events - 1] == "remove:" .. secondary)
assert(both.events[#both.events] == "RENDER_STATS")

local untouched = run_case("overwrite disabled does not remove outputs", {
    overwrite = false,
    targets = { primary, secondary },
    secondary_format = "bDNwbQ==",
}, true)
assert(#untouched.removed == 0 and untouched.render_count == 1)

local failed, failure_reason = run_case("failed removal stops before render", {
    overwrite = true,
    remove_failure = primary,
}, false)
assert(failed.render_count == 0 and #failed.removed == 1 and failed.files[primary])
assert(failure_reason and failure_reason:find(primary, 1, true), "Removal failure should identify the exact output")

local duplicate = run_case("duplicate targets rejected before removal", {
    overwrite = true,
    targets = { primary, primary },
}, false)
assert(#duplicate.removed == 0 and duplicate.render_count == 0)
assert(duplicate.files[primary], "Invalid target plan removed an existing output")

local canceled = run_case("cancel after overwrite remains unsuccessful", {
    overwrite = true,
    cancel = true,
}, false)
assert(#canceled.removed == 1 and canceled.render_count == 1)

local missing, missing_reason = run_case("primary statistics do not conceal missing secondary output", {
    overwrite = true,
    targets = { primary, secondary },
    secondary_format = "bDNwbQ==",
    missing_output = secondary,
}, false)
assert(missing.render_count == 1 and missing.files[primary] and not missing.files[secondary])
assert(missing_reason:find("missing"), "Missing secondary output should stop the sequence")

print(string.format("PASS: %d render overwrite cases", cases))
