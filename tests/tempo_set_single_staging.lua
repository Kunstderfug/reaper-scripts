-- Run from the repo root: TMPDIR=<scratch folder> lua tests/tempo_set_single_staging.lua
-- Single Tempo Set re-render: run-folder ownership, final prune markers, pass
-- eligibility per real render pass, and case-insensitive output name collisions.
local T = dofile("tests/tempo_set_single_support.lua")
local root, single, real_fs = T.root, T.single, T.real_fs
local equal, sh, read, write, find = T.equal, T.sh, T.read, T.write, T.find
local row_line, world, plan_of, find_region, find_tempo = T.row_line, T.world, T.plan_of, T.find_region, T.find_tempo
local request, render, audio_path = T.request, T.render, T.audio_path
local assert_restored, assert_consistent, manifest_text, snapshot =
    T.assert_restored, T.assert_consistent, T.manifest_text, T.snapshot

sh('mkdir -p "' .. root .. '"')

-- Deterministic run creation times, so "newest" is well defined.
local clock = 5000
single._fs.time = function() clock = clock + 1; return clock end

local function work_of(w) return w.dir .. "/.gphildeck-rerender/" end
local function region_request(w, plan, name, run, extra)
    local overrides = { scope = "region", region = find_region(plan, name).id, run = run }
    for key, value in pairs(extra or {}) do overrides[key] = value end
    return request(w, plan, overrides)
end
local EXPO_100 = "AUDIO/EXPO_1/BEETHOVEN_3_1_EXPO_1_100.flac"

-- 1a: a run never reuses an existing run folder, even one with an old "done".
do
    local w = world({ audio_check = false })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    local reused = string.rep("f", 32)
    local old_manifest = "created\t1\nstage\t" .. EXPO_100 .. "\nprevious\t" .. EXPO_100 .. "\ndone\t2\n"
    write(work_of(w) .. reused .. "/manifest.txt", old_manifest)
    write(work_of(w) .. reused .. "/previous/" .. EXPO_100, "older EXPO 100")
    local plan = plan_of(w)
    local result = render(w, region_request(w, plan, "EXPO_1", reused))
    assert(result.state == "failed" or result.state == "rejected", "reused run refused: " .. result.state)
    assert(result.message:find("already exists", 1, true) and result.message:find("nothing was rendered or moved", 1, true),
        result.message)
    equal(#w.passes, 0, "reused run: nothing rendered")
    equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", "reused run: output untouched")
    equal(read(work_of(w) .. reused .. "/manifest.txt"), old_manifest, "reused run: manifest untouched")
    equal(read(work_of(w) .. reused .. "/previous/" .. EXPO_100), "older EXPO 100", "reused run: old copy untouched")
    equal(result.passes_completed, 0, "reused run: no pass")
    assert_restored(w, result)

    -- An empty folder of the same name is refused too.
    local empty = string.rep("e", 32)
    sh('mkdir -p "' .. work_of(w) .. empty .. '"')
    result = render(w, region_request(w, plan_of(w), "EXPO_1", empty))
    assert(result.message:find("already exists", 1, true), "empty run folder refused: " .. result.message)
    equal(#w.passes, 0, "empty run folder: nothing rendered")
    equal(read(work_of(w) .. empty .. "/manifest.txt"), nil, "empty run folder: no manifest written")

    -- A run id that is not hex is rejected before any effect.
    local before = snapshot(w)
    result = render(w, region_request(w, plan_of(w), "EXPO_1", "../" .. string.rep("a", 29)))
    equal({ result.state, result.message }, { "rejected", "The re-render run identifier is not valid." }, "bad run id")
    equal(snapshot(w), before, "bad run id: no effect")

    -- A multi-pass run creates its folder once and uses it for every pass.
    local fresh = string.rep("d", 32)
    result = render(w, request(w, plan_of(w), { run = fresh }))
    equal({ result.state, result.passes_completed }, { "completed", 2 }, "multi-pass run in one new folder")
    assert(manifest_text(w, fresh):find("^created\t%d+\n") and manifest_text(w, fresh):find("\ndone\t%d+\n$"),
        "one created line first, done last")
end

-- 1b: "done" counts only as the manifest's complete last line.
do
    local w = world({ audio_check = false })
    local work = work_of(w)
    local manifests = {
        ["0000"] = "created\t1001\nprevious\tAUDIO/X/b.flac\ndone\t1100\nprevious\tAUDIO/X/b.flac\n", -- line after done
        ["0001"] = "created\t1002\ndone\t1101\ndiscardable\t1102\nstage\tAUDIO/X/a.flac\n",       -- markers then more
        ["0002"] = "created\t1003\nprevious\tAUDIO/X/b.flac\ndone\t1103",                         -- incomplete line
        ["0003"] = "created\t1004\nprevious\tAUDIO/X/b.flac\ndone\t1104\n",                       -- marked
        ["0004"] = "created\t1005\nprevious\tAUDIO/X/b.flac\ndiscardable\t1105\n"                 -- marked
    }
    for name, text in pairs(manifests) do
        write(work .. name .. "/manifest.txt", text)
        write(work .. name .. "/previous/AUDIO/X/b.flac", "b " .. name)
    end
    for i = 1, 3 do
        local plan = plan_of(w)
        local result = render(w, region_request(w, plan, "EXPO_1", string.rep("b", 31) .. i))
        equal(result.state, "completed", "later run " .. i)
    end
    for _, name in ipairs({ "0000", "0001", "0002" }) do
        equal(read(work .. name .. "/previous/AUDIO/X/b.flac"), "b " .. name, name .. ": unmarked run never pruned")
        equal(read(work .. name .. "/manifest.txt"), manifests[name], name .. ": manifest untouched")
    end
    for _, name in ipairs({ "0003", "0004" }) do
        equal(read(work .. name .. "/previous/AUDIO/X/b.flac"), nil, name .. ": marked run pruned")
        equal(read(work .. name .. "/manifest.txt"), nil, name .. ": marked manifest pruned")
    end
end

-- 1c: stopped runs that left nothing in previous/ are marked discardable and pruned
-- like finished ones; runs with a backup left behind stay unmarked forever.
do
    local w = world({ decline = 1 })
    write(audio_path(w, "EXPO_1", 100), "old EXPO 100")
    local canceled = string.rep("c", 32)
    local result = render(w, region_request(w, plan_of(w), "EXPO_1", canceled))
    equal(result.state, "canceled", "declined checkpoint")
    assert(manifest_text(w, canceled):find("\ndiscardable\t%d+\n$"), "canceled run marked discardable last")
    local staged = result.staged_dir .. "/" .. EXPO_100
    assert(read(staged), "canceled run's staged audio kept for inspection")
    equal(result.previous_dir, nil, "nothing in previous/")
    equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", "canceled: output untouched")
    assert_restored(w, result)

    -- A swap failure that rolled back completely is discardable too.
    local rolled = string.rep("a", 31) .. "0"
    local calls = 0
    single._fs.rename = function(from, to)
        calls = calls + 1
        if calls == 2 then return nil, "injected move failure" end -- staged file into place
        return real_fs.rename(from, to)
    end
    result = render(w, region_request(w, plan_of(w), "EXPO_1", rolled))
    single._fs.rename = real_fs.rename
    assert(result.state == "failed" and result.message:find("rolled back", 1, true), result.message)
    equal(result.previous_dir, nil, "rolled back: nothing in previous/")
    assert(manifest_text(w, rolled):find("\ndiscardable\t%d+\n$"), "rolled-back run marked discardable last")
    equal(read(audio_path(w, "EXPO_1", 100)), "old EXPO 100", "rolled back: old output in place")

    -- Pass 1 replaced, pass 2 canceled: pass 1's backup stays, so the run is unmarked.
    local w2 = world({ decline = 2 })
    write(audio_path(w2, "EXPO_1", 100), "old EXPO 100")
    local partial = string.rep("9", 32)
    result = render(w2, request(w2, plan_of(w2), { run = partial }))
    equal({ result.state, result.passes_completed }, { "canceled", 1 }, "second pass declined")
    local backup = work_of(w2) .. partial .. "/previous/" .. EXPO_100
    equal(read(backup), "old EXPO 100", "pass 1 backup in previous/")
    local text = manifest_text(w2, partial)
    assert(not text:find("discardable", 1, true) and not text:find("done", 1, true), "partial run stays unmarked")

    -- Two newer marked runs: the oldest marked runs (canceled, then rolled back) go.
    for i = 1, 3 do
        result = render(w, region_request(w, plan_of(w), "EXPO_1", string.rep("7", 31) .. i))
        equal(result.state, "completed", "newer run " .. i)
        result = render(w2, region_request(w2, plan_of(w2), "DEV_2", string.rep("7", 31) .. i))
        equal(result.state, "completed", "newer run beside the partial run " .. i)
    end
    equal(read(staged), nil, "discardable canceled run pruned once two newer marked runs exist")
    equal(manifest_text(w, canceled), "", "canceled manifest pruned")
    equal(manifest_text(w, rolled), "", "rolled-back manifest pruned")
    equal(read(backup), "old EXPO 100", "a run with a backup left in previous/ is never pruned")
    equal(manifest_text(w2, partial), text, "partial manifest untouched")
end

-- 2: eligibility is per real render pass, not per rounded public tempo key.
-- Multiplier 4: 119.4999997 -> suffix 119; 119.5000001 and 119.5000005 -> suffix 120
-- (two passes, one file name). The first two share the public key t119500000.
do
    local r = world().regions
    local w = world({ multiplier = 4, audio_check = false,
        blob = row_line(r[1], 120, 119.4999997, 0.0000004, 119.5000006) })
    write(audio_path(w, "EXPO_1", 119), "old EXPO 119")
    write(audio_path(w, "EXPO_1", 120), "old EXPO 120")
    local plan = plan_of(w)
    assert_consistent(plan, "suffix split plan")
    local expo = find_region(plan, "EXPO_1")
    equal(expo.targets, { "t119500000" }, "only the eligible pass's key is a target")
    local tempo = find_tempo(plan, "t119500000")
    equal({ #plan.tempos, tempo.passes, tempo.suffix }, { 1, 1, "119" }, "one eligible pass at suffix 119")
    local reported = false
    for _, issue in ipairs(plan.issues) do reported = reported or issue:find("same file suffix 120", 1, true) ~= nil end
    assert(reported, "suffix 120 exclusion reported")
    local result = render(w, request(w, plan, { tempo = "t119500000" }))
    equal({ result.state, result.passes, #w.passes }, { "completed", 1, 1 }, "one press renders only the eligible pass")
    assert(w.passes[1].pattern:find("_119$"), "the rendered pass is suffix 119: " .. w.passes[1].pattern)
    equal(read(audio_path(w, "EXPO_1", 120)), "old EXPO 120", "the excluded suffix 120 file is untouched")
    equal(read(audio_path(w, "EXPO_1", 119)), "new audio pass 1", "the suffix 119 file is replaced")
    assert_restored(w, result)
end

-- 3: output names collide case-insensitively, including accented letters.
do
    local fold = single._fold_case
    equal(fold("Étude"), fold("étude"), "Latin-1 fold")
    equal(fold("ŁÓDŹ ŒUVRE Ÿ"), fold("łódź œuvre ÿ"), "Latin Extended-A fold")
    equal(fold("ΣΟΦΊΑ"), fold("σοφία"), "Greek fold")
    equal(fold("ΣΟΦΟΣ"), fold("σοφος"), "final sigma fold")
    equal(fold("МОСКВА ЁЖ"), fold("москва ёж"), "Cyrillic fold")
    equal(fold("A×B"), "a×b", "multiplication sign is not a letter")
    equal(fold("X\255\128É\195"), "x\255\128é\195", "invalid UTF-8 bytes kept as they are")
    assert(fold("Straße") ~= fold("STRASSE"), "no multi-letter folding needed")

    local regions = {
        { index = 0, pos = 0, rgnend = 16, name = "Étude", number = 1, B_UISEL = 0 },
        { index = 1, pos = 20, rgnend = 30, name = "étude", number = 2, B_UISEL = 0 },
        { index = 2, pos = 40, rgnend = 50, name = "CODA_3", number = 3, B_UISEL = 0 }
    }
    local w = world({ regions = regions, blob = table.concat({
        row_line(regions[1], 120, 100, 10, 120), row_line(regions[2], 100, 100, 5, 110),
        row_line(regions[3], 120, 110, 10, 110) }, "\n") })
    local plan = plan_of(w)
    assert_consistent(plan, "case collision plan")
    for _, name in ipairs({ "Étude", "étude" }) do
        local region = find_region(plan, name)
        equal(region.targets, {}, name .. " left out")
        assert(region.note and region.note:find("same name", 1, true), name .. " note: " .. tostring(region.note))
    end
    equal(find_region(plan, "CODA_3").targets, { "t110000000" }, "other regions still planned")
    assert(find(plan.issues, "Regions named Étude share an output name; they were left out."), "collision reported")
end

single._fs.time = real_fs.time
sh('rm -rf "' .. root .. '"')
print("tempo_set_single_staging: PASS")
