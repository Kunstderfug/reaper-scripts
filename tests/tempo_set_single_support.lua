-- Shared fake REAPER and helpers for the single Tempo Set re-render tests.
-- Loaded by tests/tempo_set_single.lua and tests/tempo_set_single_staging.lua;
-- run those from the repo root with TMPDIR=<scratch folder>.
local scratch = assert(os.getenv("TMPDIR"), "Set TMPDIR to a scratch folder")
local root = scratch .. "/tempo-set-single-" .. tostring(os.time()) .. "-" .. tostring(math.random(1, 1e9))
local single = dofile("lib/tempo_set_single.lua")
local plan_lib = dofile("lib/tempo_set_plan.lua")
local real_fs = {}
for key, value in pairs(single._fs) do real_fs[key] = value end

local function clone(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, entry in pairs(value) do result[key] = clone(entry) end
    return result
end
local function equal(actual, expected, label)
    if type(expected) == "table" then
        assert(type(actual) == "table", label .. ": expected table, got " .. tostring(actual))
        for key, value in pairs(expected) do equal(actual[key], value, label .. "." .. tostring(key)) end
        for key in pairs(actual) do assert(expected[key] ~= nil, label .. ": unexpected key " .. tostring(key)) end
    elseif type(expected) == "number" then
        assert(type(actual) == "number" and math.abs(actual - expected) < 1e-8,
            string.format("%s: expected %s, got %s", label, expected, tostring(actual)))
    else
        assert(actual == expected, string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end
local function sh(command) assert(os.execute(command), command) end
local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read("a")
    file:close()
    return data
end
local function write(path, data)
    sh('mkdir -p "' .. path:match("^(.*)/") .. '"')
    local file = assert(io.open(path, "wb"))
    file:write(data)
    file:close()
end
local function listing(directory, folders_only)
    local names, pipe = {}, io.popen('ls -1 -p "' .. directory .. '" 2>/dev/null')
    for name in pipe:lines() do
        local folder = name:match("^(.*)/$")
        if folder then names[#names + 1] = folder elseif not folders_only then names[#names + 1] = name end
    end
    pipe:close()
    return names
end
local function find(list, value)
    for _, entry in ipairs(list) do if entry == value then return true end end
    return false
end

-- Never a GFX window or prompt; a touch fails the test.
gfx = setmetatable({}, { __index = function(_, key) error("gfx." .. tostring(key) .. " must not be used") end })

local function row_line(region, base, min, step, max, extra)
    extra = extra or {}
    return table.concat({ region.index, region.pos, region.rgnend, extra.name or region.name, region.number, base, min, step,
        max, extra.click or 1, extra.enabled == false and 0 or 1 }, "\t")
end

-- One fake project. Regions: EXPO_1 at 120 BPM, DEV_2 at 100 BPM, CODA_3 at 120 BPM.
local case_index = 0
local function world(options)
    options = options or {}
    case_index = case_index + 1
    local w = { options = options, dir = root .. "/case" .. case_index }
    w.project_path = w.dir .. "/BEETHOVEN_3_1.RPP"
    sh('mkdir -p "' .. w.dir .. '"')
    write(w.project_path, "<REAPER_PROJECT\n>\n")
    local project, other = { "project" }, { "other" }
    w.project, w.other, w.active = project, other, project
    w.regions = options.regions or {
        { index = 0, pos = 0, rgnend = 16, name = "EXPO_1", number = 1, B_UISEL = 0 },
        { index = 1, pos = 20, rgnend = 30, name = "DEV_2", number = 2, B_UISEL = 1 },
        { index = 2, pos = 40, rgnend = 50, name = "CODA_3", number = 3, B_UISEL = 0 }
    }
    for _, region in ipairs(w.regions) do region.B_ISREGION = 1 end
    local mult = options.multiplier or 1
    w.points = options.points or {
        { time = 0, bpm = 120 * mult, num = 4, denom = 4, flags = 1, linear = false, basis = 1, pattern = "" },
        { time = 20, bpm = 100 * mult, num = 0, denom = 0, flags = 0, linear = false, basis = 1, pattern = "" },
        { time = 40, bpm = 120 * mult, num = 3, denom = 4, flags = 1, linear = false, basis = 1, pattern = "" }
    }
    w.project_bpm, w.project_bpi = 120 * mult, 4
    w.tracks = {
        { name = "Strings", B_MUTE = 0, selected = true },
        { name = "CLICKTRACK", B_MUTE = 0, selected = false },
        { name = "SOLO", B_MUTE = 0, selected = true }
    }
    for _, track in ipairs(options.extra_tracks or {}) do w.tracks[#w.tracks + 1] = track end
    local r = w.regions
    w.ext = {
        saved_region_rows_v1 = options.blob or table.concat({
            row_line(r[1], 120, 100, 10, 120), row_line(r[2], 100, 100, 5, 110), row_line(r[3], 120, 110, 10, 110)
        }, "\n"),
        -- Pending rows and options belong to the grid; the re-render must ignore them.
        pending_region_rows_v1 = row_line(r[1], 120, 60, 1, 61),
        pending_queue_options_v1 = "skip_existing=0\nmode=render_now\npause_audio_check=0"
    }
    if options.multiplier then w.ext.tempo_multiplier = tostring(options.multiplier) end
    if options.audio_check == false then w.ext.pause_audio_check_v1 = "0" end
    if options.no_blob then w.ext.saved_region_rows_v1 = nil end
    w.numeric, w.strings = {}, {}
    for _, key in ipairs(plan_lib.RENDER_NUMERIC_KEYS) do w.numeric[key] = 0 end
    w.numeric.RENDER_SETTINGS, w.numeric.RENDER_BOUNDSFLAG, w.numeric.RENDER_DELAY = 8, 1, 7
    w.numeric.RENDER_PADSTART, w.numeric.RENDER_PADEND = 0.25, 1.5
    for _, key in ipairs(plan_lib.RENDER_STRING_KEYS) do w.strings[key] = "original-" .. key end
    w.passes, w.events, w.checkpoints, w.messages, w.exits = {}, {}, {}, {}, {}
    w.undo_begin, w.undo_end, w.render_calls = 0, 0, 0
    w.original = clone({ regions = w.regions, points = w.points, tracks = w.tracks, numeric = w.numeric,
        strings = w.strings, ext = w.ext, bpm = w.project_bpm })

    local function marker_at(time)
        for _, point in ipairs(w.points) do if math.abs(point.time - time) < 1e-7 then return point end end
    end
    local function bpm_at(time)
        local result = w.project_bpm
        for _, point in ipairs(w.points) do
            if point.time > time + 1e-9 then break end
            result = point.bpm
        end
        return result
    end
    local function render_dir()
        local file = w.strings.RENDER_FILE
        if file == "" then return w.dir end
        if file:sub(1, 1) == "/" then return file end
        return w.dir .. "/" .. file
    end
    function w.targets(primary_only)
        local list = {}
        local stem = w.project_path:match("([^/]+)%.[Rr][Pp][Pp]$")
        for _, region in ipairs(w.regions) do
            if region.B_UISEL == 1 then
                local base = render_dir() .. "/" .. w.strings.RENDER_PATTERN:gsub("%$project", stem):gsub("%$region", region.name)
                list[#list + 1] = base .. ".flac"
                if w.strings.RENDER_FORMAT2 ~= "" and not primary_only then list[#list + 1] = base .. ".wav" end
            end
        end
        return list
    end
    local function native_render()
        w.render_calls = w.render_calls + 1
        local selected, bpms = {}, {}
        for _, region in ipairs(w.regions) do
            if region.B_UISEL == 1 then
                selected[#selected + 1] = region.name
                bpms[#bpms + 1] = bpm_at(region.pos)
            end
        end
        local pass = { pattern = w.strings.RENDER_PATTERN, file = w.strings.RENDER_FILE, selected = selected, bpms = bpms,
            delay = w.numeric.RENDER_DELAY, settings = w.numeric.RENDER_SETTINGS, bounds = w.numeric.RENDER_BOUNDSFLAG,
            padstart = w.numeric.RENDER_PADSTART, format2 = w.strings.RENDER_FORMAT2,
            click_mute = w.tracks[2].B_MUTE, solo_mute = w.tracks[3].B_MUTE, targets = w.targets() }
        w.passes[#w.passes + 1] = pass
        if options.on_render then options.on_render(w, #w.passes) end
        if options.render_cancel == #w.passes then return "" end
        local stats = {}
        for _, target in ipairs(pass.targets) do
            assert(not read(target), "native render must never overwrite an existing file: " .. target)
            write(target, "new audio pass " .. #w.passes)
        end
        for _, target in ipairs(w.targets(true)) do stats[#stats + 1] = "FILE:" .. target end
        return table.concat(stats, ";") .. ";"
    end
    local api = {}
    w.api = api
    api.EnumProjects = function(index)
        assert(index == -1, "only the active project is read")
        if options.no_project then return nil, "" end
        return w.active, w.active == project and (options.unsaved and "" or w.project_path) or w.dir .. "/OTHER.RPP"
    end
    api.SelectProjectInstance = function(requested) w.active = requested end
    api.ValidatePtr = function() return true end
    api.ValidatePtr2 = function() return true end
    api.GetAppVersion = function() return options.version or "7.50/macOS-arm64" end
    api.GetAllProjectPlayStates = function() return options.play_state or 0 end
    api.CountTracks = function() return #w.tracks end
    api.GetTrack = function(_, index) return w.tracks[index + 1] end
    api.GetTrackName = function(track) return true, track.name end
    api.GetMediaTrackInfo_Value = function(track, key) return assert(track[key], key) end
    api.SetMediaTrackInfo_Value = function(track, key, value) track[key] = value; return true end
    api.IsTrackSelected = function(track) return track.selected end
    api.SetTrackSelected = function(track, selected) track.selected = selected end
    api.GetNumRegionsOrMarkers = function() return #w.regions end
    api.GetRegionOrMarker = function(_, index) return w.regions[index + 1] end
    api.GetRegionOrMarkerInfo_Value = function(_, region, key)
        if key == "D_STARTPOS" then return region.pos end
        if key == "D_ENDPOS" then return region.rgnend end
        if key == "I_NUMBER" then return region.number end
        return assert(region[key], key)
    end
    api.SetRegionOrMarkerInfo_Value = function(_, region, key, value) region[key] = value; return true end
    api.GetSetRegionOrMarkerInfo_String = function(_, region) return true, region.name end
    api.GetProjExtState = function(_, section, key)
        equal(section, "renderTempoSet", "ExtState section")
        return w.ext[key] and 1 or 0, w.ext[key] or ""
    end
    api.SetProjExtState = function() error("the re-render must never write project ExtState") end
    api.GetUserInputs = function() error("the re-render must never prompt") end
    api.CountTempoTimeSigMarkers = function() return #w.points end
    api.GetTempoTimeSigMarker = function(_, index)
        local point = w.points[index + 1]
        if not point then return false end
        return true, point.time, -1, -1, point.bpm, point.num, point.denom, point.linear
    end
    api.DeleteTempoTimeSigMarker = function(_, index) table.remove(w.points, index + 1); return true end
    api.SetTempoTimeSigMarker = function(_, index, time, measure, beat, bpm, num, denom, linear)
        assert(measure == -1 and beat == -1, "time-based marker writes")
        local point = { time = time, bpm = bpm, num = num, denom = denom, linear = linear,
            flags = num > 0 and 1 or 0, basis = 1, pattern = "" }
        if index == -1 then w.points[#w.points + 1] = point else w.points[index + 1] = point end
        table.sort(w.points, function(a, b) return a.time < b.time end)
        return true
    end
    api.GetSetTempoTimeSigMarkerFlag = function(_, index, flags, set)
        local point = assert(w.points[index + 1])
        if set then point.flags = flags end
        return point.flags
    end
    api.GetSetTempoTimeSigMarkerBasis = function(_, index, basis, set)
        local point = assert(w.points[index + 1])
        if set then point.basis = basis end
        return point.basis
    end
    api.TimeMap_GetMetronomePattern = function(_, time, pattern)
        local point = assert(marker_at(time), "metronome marker exists")
        if pattern:sub(1, 4) == "SET:" then point.pattern = pattern:sub(5) end
        return 1, point.pattern
    end
    api.GetProjectTimeSignature2 = function() return w.project_bpm, w.project_bpi end
    api.SetCurrentBPM = function(_, bpm) w.project_bpm = bpm end
    api.TimeMap2_GetDividedBpmAtTime = function(_, time) return bpm_at(time) end
    api.UpdateTimeline = function() end
    api.UpdateArrange = function() end
    api.GetSetProjectInfo = function(_, key, value, set)
        if set then w.numeric[key] = value end
        return assert(w.numeric[key], key)
    end
    api.GetSetProjectInfo_String = function(_, key, value, set)
        if key == "RENDER_TARGETS" then return true, table.concat(w.targets(), ";") end
        if key == "RENDER_STATS" then
            assert(value == "42230", "render through the native render action")
            return true, native_render()
        end
        if set and options.ignore_set and options.ignore_set(w, key, value) then return false, "" end
        if set then w.strings[key] = value end
        return true, assert(w.strings[key], key)
    end
    api.GetProjectPathEx = function() return w.dir end
    api.NamedCommandLookup = function(command)
        if command == plan_lib.CMD_APPLY_GPHIL_RENDER then return options.no_preset and 0 or 9876 end
        error("unexpected command lookup: " .. tostring(command))
    end
    api.Main_OnCommand = function(command)
        assert(command == 9876, "only the GPHIL_RENDER preset action runs: " .. tostring(command))
        -- Preset values: an explicit output folder, both formats, padding and delay.
        w.strings.RENDER_FILE = options.preset_file or ""
        w.strings.RENDER_FORMAT = "flac"
        w.strings.RENDER_FORMAT2 = options.format2 and "wav" or ""
        w.numeric.RENDER_PADSTART = 0.5
        w.numeric.RENDER_SETTINGS = options.preset_delay and (16 << 16) or 0
        w.numeric.RENDER_DELAY = options.preset_delay or 0
        w.numeric.RENDER_ADDTOPROJ = options.add_to_project and 1 or 0
        w.numeric.RENDER_BOUNDSFLAG = 2
    end
    api.Undo_BeginBlock2 = function() w.undo_begin = w.undo_begin + 1 end
    api.Undo_EndBlock2 = function(_, label) w.undo_end = w.undo_end + 1; w.undo_label = label end
    api.atexit = function(fn) w.exits[#w.exits + 1] = fn end
    api.ShowConsoleMsg = function() end
    api.ShowMessageBox = function(message, title, buttons)
        assert(title == "Tempo Set: audio check required", "unexpected dialog: " .. tostring(title))
        equal(buttons, 4, "checkpoint Yes/No")
        w.checkpoints[#w.checkpoints + 1] = { message = message, file = w.strings.RENDER_FILE }
        if options.on_checkpoint then options.on_checkpoint(w, #w.checkpoints) end
        return options.decline == #w.checkpoints and 7 or 6
    end
    api.file_exists = function(path) return read(path) ~= nil end
    api.RecursiveCreateDirectory = function(path) sh('mkdir -p "' .. path .. '"'); return 1 end
    api.EnumerateSubdirectories = function(path, index)
        if index < 0 then return nil end
        return listing(path, true)[index + 1]
    end
    return w
end

local function plan_of(w) return single.plan(w.api) end
local function find_region(plan, name)
    for _, region in ipairs(plan.regions) do if region.name == name then return region end end
end
local function find_tempo(plan, key)
    for _, tempo in ipairs(plan.tempos) do if tempo.key == key then return tempo end end
end
local function request(w, plan, overrides)
    local result = { contract = 1, run = string.rep("a", 31) .. tostring(case_index % 10), project = plan.project.id,
        revision = plan.revision, scope = "tempo", tempo = "t100000000", region = nil,
        audio_check = plan.audio_check, replace = "staged-music-v1" }
    for key, value in pairs(overrides or {}) do
        if value == false and key ~= "audio_check" then result[key] = nil else result[key] = value end
    end
    return result
end
local last_run = {}
local function req_run(result) return last_run[result] end
local function render(w, req)
    w.events = {}
    local result = single.render(w.api, req, function(event) w.events[#w.events + 1] = clone(event) end)
    last_run[result] = req.run
    return result
end
local function audio_path(w, region, tempo, extension)
    return w.dir .. "/AUDIO/" .. region .. "/BEETHOVEN_3_1_" .. region .. "_" .. tempo .. "." .. (extension or "flac")
end
local function assert_restored(w, result)
    equal(result.restored, true, "restored")
    equal(result.restore_errors, {}, "restore errors")
    equal(w.regions, w.original.regions, "regions and selection restored")
    equal(w.points, w.original.points, "tempo/meter map restored")
    equal(w.tracks, w.original.tracks, "track mutes and selection restored")
    equal(w.numeric, w.original.numeric, "numeric render settings restored")
    equal(w.strings, w.original.strings, "string render settings restored")
    equal(w.ext, w.original.ext, "ExtState untouched")
    equal(w.project_bpm, w.original.bpm, "project tempo restored")
    equal(w.undo_begin, w.undo_end, "undo block closed")
end
-- Every region target is a planned tempo listing that region, and back.
local function assert_consistent(plan, label)
    local by_key, by_id = {}, {}
    for _, region in ipairs(plan.regions) do by_id[region.id] = region end
    for _, tempo in ipairs(plan.tempos) do
        assert(not by_key[tempo.key], label .. ": duplicate tempo " .. tempo.key)
        by_key[tempo.key] = tempo
        assert(tonumber(tempo.key:sub(2)) > 0 and tempo.tempo > 0, label .. ": tempo above 0 " .. tempo.key)
        assert(#tempo.regions > 0 and tempo.passes > 0, label .. ": tempo is used " .. tempo.key)
        for _, id in ipairs(tempo.regions) do
            assert(by_id[id] and find(by_id[id].targets, tempo.key), label .. ": region lists " .. tempo.key)
        end
    end
    for _, region in ipairs(plan.regions) do
        for _, key in ipairs(region.targets) do
            assert(by_key[key] and find(by_key[key].regions, region.id), label .. ": " .. region.name .. " target " .. key)
        end
    end
end
-- Fails the nth manifest append with the given failure ("open" or "write").
local function fail_append(n, how)
    local count = 0
    single._fs.open = function(path, mode)
        if mode == "a" then
            count = count + 1
            if count == n then
                if how == "open" then return nil, "injected open failure" end
                return { write = function() return nil, "injected write failure" end, close = function() return true end }
            end
        end
        return real_fs.open(path, mode)
    end
end
local function manifest_text(w, run)
    return read(w.dir .. "/.gphildeck-rerender/" .. run .. "/manifest.txt") or ""
end
local function snapshot(w)
    return clone({ regions = w.regions, points = w.points, tracks = w.tracks, numeric = w.numeric,
        strings = w.strings, ext = w.ext, bpm = w.project_bpm, undo = w.undo_begin, renders = w.render_calls })
end


return {
    scratch = scratch,
    root = root,
    single = single,
    plan_lib = plan_lib,
    real_fs = real_fs,
    clone = clone,
    equal = equal,
    sh = sh,
    read = read,
    write = write,
    listing = listing,
    find = find,
    row_line = row_line,
    world = world,
    plan_of = plan_of,
    find_region = find_region,
    find_tempo = find_tempo,
    request = request,
    req_run = req_run,
    render = render,
    audio_path = audio_path,
    assert_restored = assert_restored,
    assert_consistent = assert_consistent,
    fail_append = fail_append,
    manifest_text = manifest_text,
    snapshot = snapshot,
}
