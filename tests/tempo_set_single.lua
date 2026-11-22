-- Run from the repo root: TMPDIR=<scratch folder> lua tests/tempo_set_single.lua
-- GPhilDeck single Tempo Set re-render (Contract v1) against a stateful fake REAPER
-- whose renders write real files under TMPDIR. Optional: GPHILDECK_DISPATCH=<path to
-- GPhilDeck_dispatch.lua> also drives a scratch copy of the Deck dispatcher.
local T = dofile("tests/tempo_set_single_support.lua")
local scratch = T.scratch
local root = T.root
local single = T.single
local plan_lib = T.plan_lib
local real_fs = T.real_fs
local clone = T.clone
local equal = T.equal
local sh = T.sh
local read = T.read
local write = T.write
local listing = T.listing
local find = T.find
local row_line = T.row_line
local world = T.world
local plan_of = T.plan_of
local find_region = T.find_region
local find_tempo = T.find_tempo
local request = T.request
local req_run = T.req_run
local render = T.render
local audio_path = T.audio_path
local assert_restored = T.assert_restored
local assert_consistent = T.assert_consistent
local fail_append = T.fail_append
local manifest_text = T.manifest_text
local snapshot = T.snapshot

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
    assert_consistent(plan, "basic plan")

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
    assert_consistent(plan, "plan with exclusions")

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
    equal(result.previous_dir, nil, "a full rollback leaves nothing in previous/, so no previous dir")
    assert(not manifest_text(w, req_run(result)):find("\ndone\t"), "a failed run is never marked done")
    assert_restored(w, result)
end

-- A failed rollback reports uncertainty and the backup location truthfully.
do
    local w = world({ format2 = true })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    write(audio_path(w, "EXPO_1", 100, "wav"), "old EXPO 100 wav")
    local calls = 0
    single._fs.rename = function(from, to)
        calls = calls + 1
        if calls == 3 or calls == 5 then return nil, "injected move failure" end
        return real_fs.rename(from, to)
    end
    local plan = plan_of(w)
    local req = request(w, plan, { scope = "region", region = find_region(plan, "EXPO_1").id })
    local result = render(w, req)
    single._fs.rename = real_fs.rename
    equal(result.state, "failed", "incomplete rollback fails")
    assert(result.message:find("Rollback was incomplete", 1, true), result.message)
    assert(not result.message:find("old outputs are in place", 1, true), result.message)
    assert(not result.message:find("Old outputs for the stopped pass were not changed", 1, true), result.message)
    local previous = w.dir .. "/.gphildeck-rerender/" .. req.run .. "/previous"
    equal(result.previous_dir, previous, "incomplete rollback reports backup directory")
    equal(read(previous .. "/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"), "old EXPO 100", "stranded old file located")
    equal(read(audio_path(w, "EXPO_1", 100)), nil, "canonical file could not be restored")
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
    for i, name in ipairs({ "0000", "0001", "0002", "0003" }) do
        -- 0000 has no done marker: an old, failed or interrupted run, never pruned.
        write(work .. name .. "/manifest.txt", "created\t" .. (1000 + i) .. "\nstage\tAUDIO/X/a.flac\nprevious\tAUDIO/X/b.flac\n"
            .. (name == "0000" and "" or "done\t" .. (1100 + i) .. "\n"))
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
    equal(read(work .. "0000/previous/AUDIO/X/b.flac"), "b", "run without a done marker is never pruned")
    equal(read(work .. "0000/manifest.txt"):find("done", 1, true), nil, "unmarked manifest untouched")
    assert(manifest_text(w, req_run(result)):find("\ndone\t%d+\n$"), "a completed run is marked done last")
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

-- A: a manifest failure inside the swap rolls the pass back and says so truthfully.
do
    for _, case in ipairs({ { 4, "open", "after the first file moved" }, { 3, "write", "before any move" } }) do
        local w = world({ format2 = true })
        write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
        write(audio_path(w, "EXPO_1", 100, "wav"), "old EXPO 100 wav")
        local plan = plan_of(w)
        fail_append(case[1], case[2])
        local result = render(w, request(w, plan, { scope = "region", region = find_region(plan, "EXPO_1").id }))
        single._fs.open = real_fs.open
        local label = "manifest " .. case[2] .. " failure " .. case[3]
        equal(result.state, "failed", label)
        assert(result.message:find("Could not write the re-render manifest", 1, true), label .. ": " .. result.message)
        assert(result.message:find("rolled back", 1, true), label .. ": " .. result.message)
        equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", label .. ": flac in place")
        equal(read(audio_path(w, "EXPO_1", 100, "wav")), "old EXPO 100 wav", label .. ": wav in place")
        equal(result.previous_dir, nil, label .. ": nothing left in previous/")
        assert(result.staged_dir and read(result.staged_dir .. "/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"), label .. ": staged kept")
        assert_restored(w, result)
    end

    -- An unexpected error during a move is contained and rolled back too.
    local w = world({ format2 = true })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    write(audio_path(w, "EXPO_1", 100, "wav"), "old EXPO 100 wav")
    local calls = 0
    single._fs.rename = function(from, to)
        calls = calls + 1
        if calls == 3 then error("injected crash") end
        return real_fs.rename(from, to)
    end
    local plan = plan_of(w)
    local result = render(w, request(w, plan, { scope = "region", region = find_region(plan, "EXPO_1").id }))
    single._fs.rename = real_fs.rename
    equal(result.state, "failed", "raised move fails")
    assert(result.message:find("injected crash", 1, true) and result.message:find("rolled back", 1, true), result.message)
    equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", "raised move: flac rolled back")
    equal(result.previous_dir, nil, "raised move: nothing left in previous/")
    assert_restored(w, result)

    -- A later pass failing after an earlier pass replaced files still reports previous/.
    w = world({ audio_check = false })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    write(audio_path(w, "DEV_2", 100), "old DEV 100")
    plan = plan_of(w)
    local req = request(w, plan)
    fail_append(4, "open") -- stage EXPO, previous EXPO, stage DEV, previous DEV
    result = render(w, req)
    single._fs.open = real_fs.open
    equal({ result.state, result.passes_completed }, { "failed", 1 }, "second pass manifest failure")
    equal(read(audio_path(w, "DEV_2", 100)), "old DEV 100", "second pass old output in place")
    local previous = w.dir .. "/.gphildeck-rerender/" .. req.run .. "/previous"
    equal(result.previous_dir, previous, "first pass backup still reported")
    equal(read(previous .. "/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"), "old EXPO 100", "first pass backup kept")
    assert_restored(w, result)
end

-- C: a stranded recovery copy survives any number of later successful runs.
do
    local w = world({ format2 = true })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    write(audio_path(w, "EXPO_1", 100, "wav"), "old EXPO 100 wav")
    local calls = 0
    single._fs.rename = function(from, to)
        calls = calls + 1
        if calls == 3 or calls == 5 then return nil, "injected move failure" end
        return real_fs.rename(from, to)
    end
    local plan = plan_of(w)
    local region = find_region(plan, "EXPO_1").id
    local stranded = string.rep("1", 32)
    local result = render(w, request(w, plan, { scope = "region", region = region, run = stranded }))
    single._fs.rename = real_fs.rename
    assert(result.message:find("Rollback was incomplete", 1, true), result.message)
    local work = w.dir .. "/.gphildeck-rerender/"
    local copy = work .. stranded .. "/previous/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"
    equal(read(copy), "old EXPO 100", "only copy of the old flac is in previous/")
    for i = 1, 4 do
        result = render(w, request(w, plan_of(w), { scope = "region", region = region, run = string.rep("b", 31) .. i }))
        equal(result.state, "completed", "later run " .. i .. ": " .. result.message)
    end
    equal(read(copy), "old EXPO 100", "recovery copy never pruned")
    equal(manifest_text(w, stranded):find("done", 1, true), nil, "the failed run stays unmarked")
    equal(read(work .. string.rep("b", 31) .. "1/previous/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.wav"), nil,
        "finished runs beyond the newest two are still pruned")
    equal(read(work .. string.rep("b", 31) .. "2/previous/AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.wav"), "new audio pass 2",
        "newest finished runs kept")
end

-- D: a region outside the saved grid with the same output name excludes the saved row.
do
    local regions = {
        { index = 0, pos = 0, rgnend = 16, name = "EXPO_1", number = 1, B_UISEL = 0 },
        { index = 1, pos = 20, rgnend = 30, name = "DEV_2", number = 2, B_UISEL = 0 },
        { index = 2, pos = 40, rgnend = 50, name = "CODA_3", number = 3, B_UISEL = 0 },
        { index = 3, pos = 60, rgnend = 70, name = "expo_1", number = 4, B_UISEL = 0 }
    }
    local w = world({ regions = regions, blob = table.concat({
        row_line(regions[1], 120, 100, 10, 120), row_line(regions[2], 100, 100, 5, 110),
        row_line(regions[3], 120, 110, 10, 110) }, "\n") })
    local plan = plan_of(w)
    equal(plan.status, "ready", "unsaved twin plan")
    local expo = find_region(plan, "EXPO_1")
    equal(expo.targets, {}, "saved row sharing a name with an unsaved region is excluded")
    assert(expo.note:find("same name", 1, true), "name note")
    assert(table.concat(plan.issues, "\n"):find("named EXPO_1", 1, true), "name issue")
    equal(find_region(plan, "DEV_2").targets, { "t100000000", "t105000000", "t110000000" }, "others unaffected")
    assert(not find_tempo(plan, "t120000000"), "no tempo left only for the excluded region")
    assert_consistent(plan, "unsaved twin")
end

-- E: target tempos at or below 0 BPM are left out and refused.
do
    local r = world().regions
    local w = world({ blob = table.concat({ row_line(r[1], 120, -5, 5, 10), row_line(r[2], 100, 100, 5, 110) }, "\n") })
    local plan = plan_of(w)
    equal(plan.status, "ready", "non-positive plan")
    local expo = find_region(plan, "EXPO_1")
    equal(expo.targets, { "t5000000", "t10000000" }, "only tempos above 0 planned")
    assert(expo.note:find("0 BPM", 1, true), "non-positive note")
    assert(table.concat(plan.issues, "\n"):find("EXPO_1 has saved tempos at or below 0 BPM", 1, true), "non-positive issue")
    assert(not find_tempo(plan, "t0") and not find_tempo(plan, "t-5000000"), "no non-positive tempo entries")
    assert_consistent(plan, "non-positive")
    for _, key in ipairs({ "t0", "t-5000000" }) do
        local message = single.validate(w.api, request(w, plan, { scope = "region", region = expo.id, tempo = key }))
        assert(message and message:find("greater than 0 BPM", 1, true), key .. ": " .. tostring(message))
    end
    equal(single.validate(w.api, request(w, plan, { scope = "region", region = expo.id, tempo = "t5000000" })), nil,
        "positive tempo from the same row is valid")
end

-- F: tempos the multiplier merges into one pass share that pass's key.
do
    local r = world().regions
    local w = world({ multiplier = 0.25, audio_check = false,
        blob = table.concat({ row_line(r[1], 120, 100, 5, 100), row_line(r[3], 120, 100.000001, 5, 100.000001) }, "\n") })
    local plan = plan_of(w)
    equal(plan.status, "ready", "merged plan: " .. plan.message)
    local expo, coda = find_region(plan, "EXPO_1"), find_region(plan, "CODA_3")
    equal(#plan.tempos, 1, "one tempo")
    equal(plan.tempos[1].key, "t100000000", "first-seen tempo key")
    equal(plan.tempos[1].regions, { expo.id, coda.id }, "both regions at the merged tempo")
    equal(plan.tempos[1].passes, 1, "one native pass, as the GFX script renders it")
    equal(coda.targets, { "t100000000" }, "merged target uses the pass key")
    assert(table.concat(plan.issues, "\n"):find("100.000001 is rendered as 100", 1, true), "merge issue")
    assert_consistent(plan, "merged")
    local result = render(w, request(w, plan))
    equal(result.state, "completed", "merged render: " .. result.message)
    equal(#w.passes, 1, "one pass rendered")
    equal(w.passes[1].selected, { "EXPO_1", "CODA_3" }, "both regions in the pass")
    assert_restored(w, result)
end

-- G: a render setting that does not come back makes restored false and is named.
do
    local w = world({ audio_check = false, ignore_set = function(w, key, value)
        return key == "RENDER_FILE" and value == w.original.strings.RENDER_FILE
    end })
    local plan = plan_of(w)
    local result = render(w, request(w, plan, { scope = "region", region = find_region(plan, "DEV_2").id }))
    equal(result.state, "completed", "render itself completed")
    equal(result.restored, false, "restored is false")
    equal(result.restore_errors, { "render settings: RENDER_FILE did not return to its original value." },
        "restore error names the setting")
end

-- H: every track named like a click track is muted for music passes, then restored.
do
    local seen = {}
    local w = world({ audio_check = false, extra_tracks = {
        { name = "CLICK TRACK", B_MUTE = 0, selected = false },
        { name = "click-track (old)", B_MUTE = 1, selected = false },
        { name = "Clicks", B_MUTE = 0, selected = false }
    }, on_render = function(w)
        seen = { w.tracks[2].B_MUTE, w.tracks[4].B_MUTE, w.tracks[5].B_MUTE, w.tracks[6].B_MUTE }
    end })
    local plan = plan_of(w)
    local result = render(w, request(w, plan, { scope = "region", region = find_region(plan, "DEV_2").id }))
    equal(result.state, "completed", "click mute render")
    equal(seen, { 1, 1, 1, 0 }, "CLICKTRACK, CLICK TRACK and click-track muted; Clicks not")
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
