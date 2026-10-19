-- Run with: lua tests/tempo_marker_flags.lua [GPhil_<new>.lua ...]
-- Exercise the actual GFX capture/restore helpers without opening a project.
local scripts = #arg > 0 and arg or {
    "GPhil_tempoSet_render_gfx_direct.lua",
    "GPhil_renderStems_queue_gfx_direct.lua",
    "GPhil_soloCue_render_gfx_direct.lua"
}

local failures = 0
for _, path in ipairs(scripts) do
    local file = assert(io.open(path))
    local source = file:read("*a")
    file:close()
    -- Stop before main(), exposing only the tempo helpers in the same scope.
    local replacements
    source, replacements = source:gsub("main%(%)%s*$", "return { capture = capture_tempo_map, restore = restore_tempo_map, scale = scale_tempo_map, ensure = ensure_tempo_marker_at_time }")
    assert(replacements == 1, path .. ": expected one terminal main() call")

    local points
    local project_bpm = 120
    local api = {
        GetAppVersion = function() return "7.75" end,
        GetProjectTimeSignature2 = function() return project_bpm, 4 end,
        SetCurrentBPM = function(_, bpm) project_bpm = bpm end,
        CountTempoTimeSigMarkers = function() return #points end,
        GetTempoTimeSigMarker = function(_, index)
            local m = points[index + 1]
            return true, m.time, -1, -1, m.bpm, m.num, m.denom, m.linear
        end,
        DeleteTempoTimeSigMarker = function(_, index) table.remove(points, index + 1); return true end,
        SetTempoTimeSigMarker = function(_, index, time, _, _, bpm, num, denom, linear)
            points[index == -1 and #points + 1 or index + 1] = {
                time = time, bpm = bpm, num = num, denom = denom, linear = linear,
                flags = num > 0 and 1 or 0 }
            return true
        end,
        -- is_set selects write vs read; flag is the complete attribute bitmask.
        GetSetTempoTimeSigMarkerFlag = function(_, index, flag, is_set)
            local m = points[index + 1]
            if is_set then m.flags = flag end
            return m.flags
        end,
        TimeMap_GetMetronomePattern = function(_, _, pattern)
            return 1, pattern == "EXTENDED" and "AB" or pattern
        end
    }
    local helpers = assert(load(source, "@" .. path, "t", { reaper = api, math = math,
        string = string, table = table, tostring = tostring, tonumber = tonumber,
        ipairs = ipairs, pairs = pairs, type = type, debug = debug, dofile = dofile }))()

    assert(type(helpers.capture) == "function" and type(helpers.restore) == "function"
        and type(helpers.ensure) == "function", path .. ": required tempo helpers missing")

    for flags = 0, 31 do
        local function reset()
            points = { { time = 12, bpm = 120, num = 5, denom = 4, flags = flags, linear = true } }
        end
        reset()
        local captured = helpers.capture(0)
        helpers.restore(0, captured)
        assert(points[1].num == 5 and points[1].denom == 4, "restored meter")
        assert(points[1].time == 12 and points[1].bpm == 120 and points[1].linear, "restored marker values")
        if points[1].flags ~= flags then
            failures = failures + 1
            print(string.format("FAIL %s restore flags %d became %d (time signature active: %s)",
                path, flags, points[1].flags, tostring(points[1].flags & 1 ~= 0)))
        end
        if helpers.scale then
            reset()
            captured = helpers.capture(0)
            helpers.scale(0, captured, 1.25)
            assert(points[1].bpm == 150 and math.abs(points[1].time - 9.6) < 1e-9, "scaled marker values")
            assert(points[1].num == 5 and points[1].denom == 4, "scaled meter")
            if points[1].flags ~= flags then failures = failures + 1 end
            helpers.restore(0, captured)
            assert(points[1].time == 12 and points[1].bpm == 120, "cleanup after scaling")
            if points[1].flags ~= flags then failures = failures + 1 end
        end
        reset()
        captured = helpers.capture(0)
        helpers.ensure(0, 12, 150)
        assert(#points == 1 and points[1].num == 5 and points[1].denom == 4, "existing meter retained")
        if points[1].flags ~= flags then failures = failures + 1 end
        helpers.restore(0, captured)
        assert(points[1].bpm == 120, "cleanup after region-start adjustment")
        if points[1].flags ~= flags then failures = failures + 1 end
    end
end
assert(failures == 0, tostring(failures) .. " tempo marker metadata regressions")
print("PASS: all 32 flag combinations preserve meter and Set tempo state in GFX restore, scale, and existing region-start markers")
