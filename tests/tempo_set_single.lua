-- Run from the repo root: TMPDIR=<scratch folder> lua tests/tempo_set_single.lua
-- GPhilDeck single Tempo Set re-render (Contract v1) against a stateful fake REAPER
-- whose renders write real files under TMPDIR. Optional: GPHILDECK_DISPATCH=<path to
-- GPhilDeck_dispatch.lua> also drives a scratch copy of the Deck dispatcher.
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
local function render(w, req)
    w.events = {}
    return single.render(w.api, req, function(event) w.events[#w.events + 1] = clone(event) end)
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
local function snapshot(w)
    return clone({ regions = w.regions, points = w.points, tracks = w.tracks, numeric = w.numeric,
        strings = w.strings, ext = w.ext, bpm = w.project_bpm, undo = w.undo_begin, renders = w.render_calls })
end

sh('mkdir -p "' .. root .. '"')

-- Plan identity, revision, real scheduled targets and pass counts; read-only.
do
    local w = world()
    local before = snapshot(w)
    local plan = plan_of(w)
    equal(snapshot(w), before, "plan changes nothing")
    equal(plan.contract, 1, "contract")
    equal(plan.status, "ready", "status")
    equal(plan.project.name, "BEETHOVEN_3_1", "project basename without .RPP")
    equal(plan.project.id, single._fnv1a(w.project_path), "project id is FNV-1a of the path")
    assert(plan.project.id:match("^%x+$") and #plan.project.id == 16, "16 hex id")
    assert(plan.revision:match("^%x+$") and #plan.revision == 16, "16 hex revision")
    equal(plan_of(w).revision, plan.revision, "revision is stable")
    equal(plan.multiplier, 1, "multiplier")
    equal(plan.audio_check, true, "audio check defaults on")
    equal(plan.preset_ready, true, "preset resolves")
    local names = {}
    for _, region in ipairs(plan.regions) do names[#names + 1] = region.name end
    equal(names, { "EXPO_1", "DEV_2", "CODA_3" }, "regions in position order")
    local expo, dev = find_region(plan, "EXPO_1"), find_region(plan, "DEV_2")
    equal(expo.targets, { "t100000000", "t110000000", "t120000000" }, "EXPO targets in its own order")
    equal(dev.targets, { "t100000000", "t105000000", "t110000000" }, "DEV targets")
    equal(expo.number, 1, "integer region number")
    assert(math.type(expo.number) == "integer", "number is an integer")
    equal({ expo.base, expo.saved_base, expo.min, expo.max, expo.step }, { 120, 120, 100, 120, 10 }, "row values")
    local keys = {}
    for _, tempo in ipairs(plan.tempos) do keys[#keys + 1] = tempo.key end
    equal(keys, { "t100000000", "t110000000", "t120000000", "t105000000" }, "tempos in first-seen order")
    local t100, t110 = find_tempo(plan, "t100000000"), find_tempo(plan, "t110000000")
    equal(t100.regions, { expo.id, dev.id }, "t100 regions")
    equal(t100.passes, 2, "different bases make separate passes")
    equal(t110.regions, { expo.id, dev.id, find_region(plan, "CODA_3").id }, "t110 regions")
    equal(t110.passes, 2, "EXPO and CODA share base and target, so one pass with DEV separate")
    equal({ t100.label, t100.suffix, t100.tempo }, { "100", "100", 100 }, "label and suffix")
    for _, region in ipairs(plan.regions) do assert(region.note == nil, "no note when bases agree") end
    assert(plan._internal == nil, "no internals in the public plan")

    -- Each revision input changes it.
    local revision = plan.revision
    w.ext.saved_region_rows_v1 = w.ext.saved_region_rows_v1 .. "\n"
    assert(plan_of(w).revision ~= revision, "blob changes the revision")
    w.ext.saved_region_rows_v1 = w.original.ext.saved_region_rows_v1
    w.ext.pause_audio_check_v1 = "0"
    local off = plan_of(w)
    assert(off.revision ~= revision and off.audio_check == false, "audio flag changes the revision")
    w.ext.pause_audio_check_v1 = nil
    w.points[2].bpm = 101
    local moved = plan_of(w)
    assert(moved.revision ~= revision, "detected base changes the revision")
    assert(find_region(moved, "DEV_2").note:find("differs", 1, true), "base difference note")
    equal(find_region(moved, "DEV_2").base, 101, "detected base is used")
    w.points[2].bpm = 100
    equal(plan_of(w).revision, revision, "revision returns with the same inputs")
end

-- Missing, stale, partially stale, invalid, unsaved, no project.
do
    local w = world({ no_blob = true })
    local plan = plan_of(w)
    equal({ plan.status, plan.revision, #plan.tempos }, { "missing", "", 0 }, "missing plan")
    w.ext.saved_region_rows_v1 = ""
    equal(plan_of(w).status, "missing", "empty blob is missing")
    w.ext.saved_region_rows_v1 = "garbage"
    equal(plan_of(w).status, "invalid", "unreadable blob")
    local r = w.regions
    w.ext.saved_region_rows_v1 = row_line({ index = 0, pos = 1, rgnend = 16, name = "EXPO_1", number = 1 }, 120, 100, 10, 120)
    plan = plan_of(w)
    equal({ plan.status, plan.revision }, { "stale", "" }, "zero matches is stale")
    w.ext.saved_region_rows_v1 = row_line(r[1], 120, 100, 10, 120) .. "\n" .. row_line({ index = 9, pos = 70, rgnend = 80,
        name = "GONE", number = 9 }, 120, 100, 10, 120)
    plan = plan_of(w)
    equal(plan.status, "ready", "partial match is ready")
    equal(#plan.regions, 1, "stale row excluded")
    assert(plan.issues[1]:find("GONE", 1, true), "stale row listed in issues")
    equal(plan_of(world({ unsaved = true })).status, "unsaved", "unsaved project")
    plan = plan_of(world({ no_project = true }))
    equal({ plan.status, plan.revision }, { "no_project", "" }, "no project")
end

-- Fractional tempos, suffix collisions, shared names, disabled, invalid, ambiguous rows.
do
    local regions = {
        { index = 0, pos = 0, rgnend = 16, name = "EXPO_1", number = 1, B_UISEL = 0 },
        { index = 1, pos = 20, rgnend = 30, name = "Dup", number = 2, B_UISEL = 0 },
        { index = 2, pos = 40, rgnend = 50, name = "DUP", number = 3, B_UISEL = 0 },
        { index = 3, pos = 60, rgnend = 70, name = "OFF_4", number = 4, B_UISEL = 0 },
        { index = 4, pos = 80, rgnend = 90, name = "BAD_5", number = 5, B_UISEL = 0 },
        { index = 5, pos = 100, rgnend = 110, name = "FRAC_6", number = 6, B_UISEL = 0 },
        { index = 6, pos = 120, rgnend = 130, name = "TWIN", number = 7, B_UISEL = 0 },
        { index = 7, pos = 120, rgnend = 130, name = "TWIN", number = 7, B_UISEL = 0 }
    }
    local blob = table.concat({
        row_line(regions[1], 120, 120, 0.5, 121),     -- 120 / 120.5 (suffix 121) / 121 (suffix 121)
        row_line(regions[2], 120, 100, 10, 110),
        row_line(regions[3], 120, 100, 10, 110),
        row_line(regions[4], 120, 100, 10, 110, { enabled = false }),
        row_line(regions[5], 120, 100, -10, 110),     -- wrong direction
        row_line(regions[6], 120, 100.25, 1, 100.25), -- fractional, suffix 100
        row_line(regions[7], 120, 100, 10, 110)
    }, "\n")
    local w = world({ regions = regions, blob = blob, points = {
        { time = 0, bpm = 120, num = 4, denom = 4, flags = 1, linear = false, basis = 1, pattern = "" } } })
    local plan = plan_of(w)
    equal(plan.status, "ready", "status with exclusions")
    local expo = find_region(plan, "EXPO_1")
    equal(expo.targets, { "t120000000" }, "colliding suffix keys removed from the region")
    assert(not find_tempo(plan, "t120500000") and not find_tempo(plan, "t121000000"), "colliding tempos omitted")
    equal(find_region(plan, "Dup").targets, {}, "shared lowercase name excluded")
    equal(find_region(plan, "DUP").targets, {}, "shared lowercase name excluded (both)")
    assert(find_region(plan, "DUP").note:find("same name", 1, true), "name note")
    local off = find_region(plan, "OFF_4")
    equal({ off.enabled, #off.targets }, { false, 0 }, "disabled row reported without targets")
    equal(find_region(plan, "BAD_5").targets, {}, "invalid row excluded")
    assert(not find_region(plan, "TWIN"), "ambiguous regions excluded")
    local frac = find_tempo(plan, "t100250000")
    equal({ frac.label, frac.suffix, frac.tempo, frac.regions[1] }, { "100.25", "100", 100.25, find_region(plan, "FRAC_6").id },
        "fractional tempo")
    local issues = table.concat(plan.issues, "\n")
    for _, needle in ipairs({ "EXPO_1 has several tempos", "named DUP", "OFF_4 is turned off", "BAD_5 has invalid",
        "TWIN is ambiguous" }) do
        assert(issues:find(needle, 1, true), "issue: " .. needle .. "\n" .. issues)
    end
    for _, tempo in ipairs(plan.tempos) do assert(#tempo.regions > 0, "no empty tempo") end

    -- More than 10000 iterations is invalid.
    w.ext.saved_region_rows_v1 = row_line(regions[1], 120, 1, 0.001, 100)
    equal(plan_of(w).status, "invalid", "too many iterations")
end

-- Region scope at one tempo: music only, scope from the request, full lifecycle.
do
    local w = world({ format2 = true })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    write(audio_path(w, "EXPO_1", 100, "wav"), "old EXPO 100 wav")
    write(audio_path(w, "DEV_2", 100), "old DEV 100")
    local plan = plan_of(w)
    local expo = find_region(plan, "EXPO_1")
    local before = snapshot(w)
    local req = request(w, plan, { scope = "region", region = expo.id })
    equal(single.validate(w.api, req), nil, "valid request")
    equal(snapshot(w), before, "validate has no effects")
    local result = render(w, req)
    equal(result.state, "completed", "completed: " .. tostring(result.message))
    equal({ result.passes, result.passes_completed }, { 1, 1 }, "one pass")
    equal(#w.passes, 1, "one native render")
    local pass = w.passes[1]
    equal(pass.selected, { "EXPO_1" }, "only the requested region, not REAPER's selection (DEV_2)")
    equal(pass.pattern, "AUDIO/$region/$project_$region_100", "suffixed music pattern")
    assert(not pass.pattern:find("CLICKDATA", 1, true), "never clicks")
    equal(pass.bpms, { 100 }, "target tempo at the region start")
    equal({ pass.bounds, pass.delay, pass.settings & (16 << 16) ~= 0 }, { 5, 2, true }, "bounds and 2 s delay")
    equal({ pass.padstart, pass.format2 }, { 0.5, "wav" }, "preset padding and formats")
    equal({ pass.click_mute, pass.solo_mute }, { 1, 1 }, "click and SOLO muted")
    local stage = w.dir .. "/.gphildeck-rerender/" .. req.run .. "/stage"
    equal(pass.file, stage, "rendered into the stage folder")
    equal(#w.checkpoints, 1, "audio checkpoint ran")
    assert(w.checkpoints[1].message:find(stage, 1, true), "checkpoint points at the staged files")
    local states = {}
    for _, event in ipairs(w.events) do states[#states + 1] = event.state end
    equal(states, { "rendering", "awaiting_audio_check", "replacing" }, "events")
    equal(w.events[1].label, "EXPO_1 · 100", "event label")
    equal({ w.events[1].pass, w.events[1].passes }, { 1, 1 }, "event pass numbers")
    equal(result.outputs, { "AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac", "AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.wav" }, "outputs")
    equal(read(audio_path(w, "EXPO_1", 100)), "new audio pass 1", "flac replaced")
    equal(read(audio_path(w, "EXPO_1", 100, "wav")), "new audio pass 1", "wav replaced")
    equal(read(audio_path(w, "DEV_2", 100)), "old DEV 100", "other region untouched")
    local previous = w.dir .. "/.gphildeck-rerender/" .. req.run .. "/previous"
    equal(result.previous_dir, previous, "previous dir")
    equal(read(previous .. "/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"), "old EXPO 100", "old file kept")
    equal(result.staged_dir, nil, "nothing left staged")
    equal(w.undo_label, "renderTempoSet - GPhilDeck re-render", "undo label")
    assert(#w.exits == 1, "atexit cleanup registered")
    assert_restored(w, result)
    equal(single.validate(w.api, req), nil, "the plan does not change after a render")
end

-- Tempo scope: every planned region in group order; multiplier; preset delay kept; no audio check.
do
    local w = world({ multiplier = 2, preset_delay = 5, audio_check = false })
    local plan = plan_of(w)
    equal(plan.multiplier, 2, "multiplier read")
    equal(find_region(plan, "EXPO_1").base, 120, "base is detected / multiplier")
    local result = render(w, request(w, plan, { tempo = "t110000000" }))
    equal(result.state, "completed", "tempo scope: " .. tostring(result.message))
    equal(#w.passes, 2, "two native passes")
    equal(w.passes[1].selected, { "EXPO_1", "CODA_3" }, "first group")
    equal(w.passes[2].selected, { "DEV_2" }, "second group")
    equal(w.passes[1].bpms, { 220, 220 }, "multiplier applied to the target")
    equal(w.passes[2].delay, 5, "preset delay above 2 s kept")
    equal(#w.checkpoints, 0, "audio check off")
    equal(#result.outputs, 3, "three outputs")
    equal(result.previous_dir, nil, "nothing replaced, so no previous dir")
    assert_restored(w, result)
end

-- Rejections before any effect.
do
    local w = world()
    local plan = plan_of(w)
    local expo = find_region(plan, "EXPO_1")
    local cases = {
        { { contract = 2 }, "version" },
        { { project = string.rep("0", 16) }, "different project" },
        { { revision = string.rep("0", 16) }, "plan changed" },
        { { tempo = "t999000000" }, "no longer in the saved plan" },
        { { scope = "region", region = string.rep("0", 16) }, "not planned" },
        { { scope = "region", region = expo.id, tempo = "t105000000" }, "not planned" },
        { { audio_check = false }, "audio check" },
        { { replace = "overwrite" }, "replacement policy" }
    }
    for _, entry in ipairs(cases) do
        local req = request(w, plan, entry[1])
        local before = snapshot(w)
        local message = single.validate(w.api, req)
        assert(message and message:find(entry[2], 1, true), entry[2] .. ": " .. tostring(message))
        local result = render(w, req)
        equal({ result.state, result.message, result.restored }, { "rejected", message, true }, "render rejects " .. entry[2])
        equal(snapshot(w), before, "no effect for " .. entry[2])
    end
    local function rejected(options, needle)
        local other = world(options)
        local before = snapshot(other)
        local result = render(other, request(other, plan_of(other)))
        assert(result.state == "rejected" and result.message:find(needle, 1, true), needle .. ": " .. tostring(result.message))
        equal(snapshot(other), before, "no effect: " .. needle)
    end
    rejected({ play_state = 1 }, "Stop playback")
    rejected({ play_state = 5 }, "recording")
    rejected({ version = "6.67/macOS" }, "6.68")
    rejected({ unsaved = true }, "Save the project")
    local missing = world({ no_preset = true })
    local missing_plan = plan_of(missing)
    equal({ missing_plan.status, missing_plan.preset_ready }, { "ready", false }, "missing preset reported")
    rejected({ no_preset = true }, "preset")
end

-- Cancel at the audio checkpoint keeps old outputs and the staged files.
do
    local w = world({ decline = 1 })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    local plan = plan_of(w)
    local req = request(w, plan)
    local result = render(w, req)
    equal(result.state, "canceled", "declined checkpoint cancels")
    equal({ result.passes, result.passes_completed }, { 2, 0 }, "no pass completed")
    equal(#w.passes, 1, "no further pass after the checkpoint")
    equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", "old output untouched")
    local stage = w.dir .. "/.gphildeck-rerender/" .. req.run .. "/stage"
    equal(result.staged_dir, stage, "staged dir reported")
    equal(read(stage .. "/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"), "new audio pass 1", "staged file kept")
    assert_restored(w, result)
end

-- A failed native render keeps old outputs; earlier completed passes stay replaced.
do
    local w = world({ render_cancel = 2 })
    write(audio_path(w, "DEV_2", 100), "old DEV 100")
    local result = render(w, request(w, plan_of(w)))
    equal(result.state, "failed", "render failure")
    equal({ result.passes, result.passes_completed }, { 2, 1 }, "first pass completed")
    equal(result.outputs, { "AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac" }, "first pass output reported")
    equal(read(audio_path(w, "EXPO_1", 100)), "new audio pass 1", "first pass replaced")
    equal(read(audio_path(w, "DEV_2", 100)), "old DEV 100", "failed pass left old output")
    assert(result.message:find("canceled or failed", 1, true), result.message)
    assert_restored(w, result)
end

-- A failed swap rolls back the whole pass.
do
    local w = world({ format2 = true })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    write(audio_path(w, "EXPO_1", 100, "wav"), "old EXPO 100 wav")
    local calls = 0
    single._fs.rename = function(from, to)
        calls = calls + 1
        if calls == 3 then return nil, "disk full" end
        return real_fs.rename(from, to)
    end
    local plan = plan_of(w)
    local result = render(w, request(w, plan, { scope = "region", region = find_region(plan, "EXPO_1").id }))
    single._fs.rename = real_fs.rename
    equal(result.state, "failed", "swap failure fails")
    assert(result.message:find("rolled back", 1, true), result.message)
    equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", "flac rolled back")
    equal(read(audio_path(w, "EXPO_1", 100, "wav")), "old EXPO 100 wav", "wav untouched")
    assert(result.staged_dir and read(result.staged_dir .. "/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"), "staged file back in place")
    equal(result.outputs, {}, "nothing replaced")
    assert_restored(w, result)
end

-- Context changes mid-run stop the run and keep old outputs.
do
    local changes = {
        { function(w) w.active = w.other end, "active project changed" },
        { function(w) w.ext.saved_region_rows_v1 = w.ext.saved_region_rows_v1 .. "\n" end, "settings changed" },
        { function(w) w.ext.tempo_multiplier = "1.5" end, "settings changed" },
        { function(w) w.regions[2].name = "RENAMED" end, "changed in REAPER" }
    }
    for _, change in ipairs(changes) do
        local w = world({ on_checkpoint = function(w, count) if count == 1 then change[1](w) end end })
        write(audio_path(w, "DEV_2", 100), "old DEV 100")
        local result = render(w, request(w, plan_of(w)))
        assert(result.state == "failed" and result.message:find(change[2], 1, true), change[2] .. ": " .. result.message)
        equal(read(audio_path(w, "DEV_2", 100)), "old DEV 100", "old output kept after " .. change[2])
        w.active = w.project
        w.ext = clone(w.original.ext)
        w.regions[2].name = "DEV_2"
        assert_restored(w, result)
    end
end

-- A preset that adds renders to the project is refused before rendering.
do
    local w = world({ add_to_project = true })
    local result = render(w, request(w, plan_of(w)))
    assert(result.state == "failed" and result.message:find("adds renders", 1, true), result.message)
    equal(#w.passes, 0, "nothing rendered")
    assert_restored(w, result)
end

-- Prune keeps the newest two other runs and deletes only manifest-listed files.
do
    local w = world({ audio_check = false })
    local work = w.dir .. "/.gphildeck-rerender/"
    for i, name in ipairs({ "0001", "0002", "0003" }) do
        write(work .. name .. "/manifest.txt", "created\t" .. (1000 + i) .. "\nstage\tAUDIO/X/a.flac\nprevious\tAUDIO/X/b.flac\n")
        write(work .. name .. "/stage/AUDIO/X/a.flac", "a")
        write(work .. name .. "/previous/AUDIO/X/b.flac", "b")
    end
    write(work .. "0001/previous/AUDIO/X/user.flac", "not ours")
    write(work .. "notes/keep.txt", "unrelated")
    local plan = plan_of(w)
    local result = render(w, request(w, plan, { scope = "region", region = find_region(plan, "EXPO_1").id }))
    equal(result.state, "completed", "prune run")
    equal(read(work .. "0001/stage/AUDIO/X/a.flac"), nil, "oldest staged file pruned")
    equal(read(work .. "0001/previous/AUDIO/X/b.flac"), nil, "oldest previous file pruned")
    equal(read(work .. "0001/previous/AUDIO/X/user.flac"), "not ours", "unlisted file kept")
    equal(read(work .. "0002/stage/AUDIO/X/a.flac"), "a", "second newest kept")
    equal(read(work .. "0003/previous/AUDIO/X/b.flac"), "b", "newest kept")
    equal(read(work .. "notes/keep.txt"), "unrelated", "unrelated folder kept")
end

-- The report callback can throw without breaking the render.
do
    local w = world({ audio_check = false })
    local plan = plan_of(w)
    local result = single.render(w.api, request(w, plan, { scope = "region", region = find_region(plan, "DEV_2").id }),
        function() error("report broke") end)
    equal(result.state, "completed", "report errors are contained")
    assert_restored(w, result)
end

-- Optional: drive a scratch copy of the Deck dispatcher with this library.
local dispatch_source = os.getenv("GPHILDECK_DISPATCH")
if dispatch_source and dispatch_source ~= "" then
    local copy = root .. "/GPhilDeck_dispatch.lua"
    write(copy, assert(read(dispatch_source), "dispatcher not found"))
    local bridge = dofile(copy)
    local w = world()
    local deck_ext = {}
    w.api.GetResourcePath = function() return root .. "/resource" end
    w.api.GetExtState = function(section, key) return deck_ext[section .. "/" .. key] or "" end
    w.api.SetExtState = function(section, key, value) deck_ext[section .. "/" .. key] = value end
    w.api.EnumerateFiles = function(directory, index)
        if index < 0 then return nil end
        return listing(directory)[index + 1]
    end
    local mailbox = root .. "/mailbox"
    local answers = {}
    bridge.tempo_plan(w.api, mailbox, function(answer) answers[#answers + 1] = answer end, single)
    local shaped = answers[1].plan
    equal({ answers[1].ok, shaped.status, shaped.project.id }, { true, "ready", single._fnv1a(w.project_path) }, "Deck plan")
    equal(#shaped.tempos, 4, "Deck keeps every tempo")
    equal(#shaped.regions, 3, "Deck keeps every region")
    answers = {}
    local run = string.rep("c", 32)
    bridge.tempo_render(w.api, mailbox, { version = "1", command = "tempo_render", expires = tostring(os.time() + 30),
        run = run, project = shaped.project.id, revision = shaped.revision, scope = "region", tempo = "t105000000",
        region = shaped.regions[2].id, audio_check = "1", replace = "staged-music-v1" },
        function(answer) answers[#answers + 1] = answer end, single)
    equal({ answers[1].ok, answers[1].state }, { true, "started" }, "Deck start answer")
    local record = assert(read(mailbox .. "/tempo-set/runs/" .. run .. ".json"), "run record")
    assert(record:find('"state":"completed"', 1, true), record)
    assert(record:find("BEETHOVEN_3_1_DEV_2_105.flac", 1, true), record)
    assert(record:find('"restored":true', 1, true), record)
    equal(deck_ext["GPhilDeck_TempoSet/active"], "", "run lock released")
    print("Deck dispatcher integration: PASS")
end

sh('rm -rf "' .. root .. '"')
print("tempo_set_single: PASS")
