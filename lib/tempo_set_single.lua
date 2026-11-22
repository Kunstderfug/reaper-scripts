-- GPhilDeck single Tempo Set re-render (Contract v1, see GPhilDeck
-- Integrations/REAPER/TEMPO_SET_CONTRACT.md). Plans and runs ONE music re-render:
-- one tempo across its planned regions, or one region at one planned tempo.
-- No GFX window, prompts or dialogs, except the existing audio checkpoint.
-- Planning, per-pass setup and rendering reuse the GFX Tempo Set code:
-- tempo_set_plan, tempo_set_project, tempo_map, render_pass, render_submission,
-- audio_checkpoint and render_session. Staged replacement lives in tempo_set_staging.
local directory = debug.getinfo(1, "S").source:sub(2):match("^(.*[/\\])") or "./"
local plan_lib = dofile(directory .. "tempo_set_plan.lua")
local render_session = dofile(directory .. "render_session.lua")
local render_pass = dofile(directory .. "render_pass.lua")
local render_submission = dofile(directory .. "render_submission.lua")
local audio_checkpoint = dofile(directory .. "audio_checkpoint.lua")
local staging_lib = dofile(directory .. "tempo_set_staging.lua")

local M = {}
M.CONTRACT = 1
M.REPLACE_POLICY = "staged-music-v1"
M.WORK_FOLDER = ".gphildeck-rerender"
M.KEEP_OTHER_RUNS = 2

-- File operations; tests replace entries to inject failures.
M._fs = {
    rename = function(from, to) return os.rename(from, to) end,
    remove = function(path) return os.remove(path) end,
    open = function(path, mode) return io.open(path, mode) end,
    time = function() return os.time() end,
    -- Renaming a path onto itself changes nothing; it fails with ENOENT (2) only
    -- when nothing is there. Any other failure counts as existing (refuse safely).
    exists = function(path)
        local ok, _, code = os.rename(path, path)
        return ok == true or code ~= 2
    end
}
local staging = staging_lib.new(M._fs)
local slash = staging_lib.slash

local CHECKPOINT_TITLE_LABEL = "GPhilDeck re-render"

-- 64-bit FNV-1a over a string, as 16 lowercase hex digits.
local function fnv1a(text)
    local hash = 0xcbf29ce484222325
    for i = 1, #text do
        hash = (hash ~ text:byte(i)) * 0x100000001b3
    end
    return string.format("%016x", hash)
end
M._fnv1a = fnv1a

local function round6(value)
    return math.floor(value * 1000000 + 0.5) / 1000000
end

local function tempo_key(tempo)
    return "t" .. plan_lib.numeric_group_key(tempo)
end

local function project_basename(path)
    local name = path:match("([^/\\]+)$") or path
    return (name:gsub("%.[Rr][Pp][Pp]$", ""))
end

local function as_integer(value)
    return math.tointeger(value) or value
end

local function ext_state(api, proj, key)
    local found, value = api.GetProjExtState(proj, plan_lib.EXT_SECTION, key)
    return found == 1, value or ""
end

local function read_multiplier(api, proj)
    -- Same fallback as the GFX script's load_last_params.
    local found, value = ext_state(api, proj, "tempo_multiplier")
    return found and tonumber(value) or 1
end

local function new_plan(status, message)
    return {
        contract = M.CONTRACT, status = status, message = message,
        project = { name = "", id = "" }, revision = "", multiplier = 1,
        audio_check = true, preset_ready = false, regions = {}, tempos = {}, issues = {}
    }
end

-- Lowercase for one code point: ASCII, Latin-1 Supplement, Latin Extended-A and
-- basic Greek and Cyrillic. Other code points are returned unchanged.
local function fold_code(c)
    if c < 0x80 then
        return (c >= 0x41 and c <= 0x5A) and c + 0x20 or c
    elseif c >= 0xC0 and c <= 0xDE and c ~= 0xD7 then
        return c + 0x20
    elseif c >= 0x100 and c <= 0x17F then
        if c == 0x178 then return 0xFF end -- Ÿ
        if c == 0x17F then return 0x73 end -- long s folds to s
        if c == 0x130 or c == 0x131 or c == 0x138 or c == 0x149 then return c end
        local odd_upper = (c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E)
        if odd_upper then return c % 2 == 1 and c + 1 or c end
        return c % 2 == 0 and c + 1 or c
    elseif c >= 0x386 and c <= 0x3AB then
        if c == 0x386 then return 0x3AC end
        if c >= 0x388 and c <= 0x38A then return c + 0x25 end
        if c == 0x38C then return 0x3CC end
        if c == 0x38E or c == 0x38F then return c + 0x3F end
        if c >= 0x391 and c ~= 0x3A2 then return c + 0x20 end
        return c
    elseif c == 0x3C2 then
        return 0x3C3 -- final sigma folds to sigma
    elseif c >= 0x400 and c <= 0x40F then
        return c + 0x50
    elseif c >= 0x410 and c <= 0x42F then
        return c + 0x20
    end
    return c
end

-- Base letters (after folding) for accented letters U+00C0..U+017F; "." keeps the letter.
local LATIN_BASE = "aaaaaa.ceeeeiiii.nooooo..uuuuy..aaaaaa.ceeeeiiii.nooooo..uuuuy.y"
    .. "aaaaaaccccccccdd..eeeeeeeeeegggg" .. "gggghh..iiiiiiiii...jjkk.llllll."
    .. "...nnnnnn...oooooo..rrrrrrssssss" .. "sstttt..uuuuuuuuuuuuwwyyyzzzzzz."
local OTHER_BASE = {
    [0x387] = 0xB7, [0x390] = 0x3B9, [0x3AC] = 0x3B1, [0x3AD] = 0x3B5, [0x3AE] = 0x3B7, [0x3AF] = 0x3B9,
    [0x3B0] = 0x3C5, [0x3CA] = 0x3B9, [0x3CB] = 0x3C5, [0x3CC] = 0x3BF, [0x3CD] = 0x3C5, [0x3CE] = 0x3C9,
    [0x439] = 0x438, [0x450] = 0x435, [0x451] = 0x435, [0x453] = 0x433, [0x457] = 0x456,
    [0x45C] = 0x43A, [0x45D] = 0x438, [0x45E] = 0x443
}
M._LATIN_BASE = LATIN_BASE

-- Code points whose every spelling this file can compare: none of them has a
-- canonical decomposition beyond the ones mapped above.
local function comparable(c)
    return c < 0x180 or (c >= 0x300 and c <= 0x36F) or (c >= 0x386 and c <= 0x3CE) or (c >= 0x400 and c <= 0x45F)
        or (c >= 0x2010 and c <= 0x2027) or (c >= 0x4E00 and c <= 0x9FFF) or (c >= 0xFE00 and c <= 0xFE0F)
        or (c >= 0x1F300 and c <= 0x1FAFF)
end

-- Output file names come from $region and land on macOS volumes that ignore
-- case and treat "É" and "E" + combining accent as the same name. The key folds
-- case, drops accents (so it may join names the volume keeps apart, which only
-- leaves both out) and is nil when the name has characters it cannot compare.
local function output_name(name)
    local text = plan_lib.sanitize_name_for_storage(name)
    if not utf8.len(text) then return nil end
    local out = {}
    for _, c in utf8.codes(text) do
        if not comparable(c) then return nil end
        if c < 0x300 or c > 0x36F then -- combining accents are dropped
            c = fold_code(c)
            if c >= 0xC0 and c <= 0x17F then
                local base = LATIN_BASE:sub(c - 0xBF, c - 0xBF)
                if base ~= "." then c = base:byte() end
            end
            out[#out + 1] = utf8.char(OTHER_BASE[c] or c)
        end
    end
    return table.concat(out)
end
M._output_name = output_name

-- A tempo with up to six decimals and no trailing zeros, e.g. "100.000001".
local function bpm_text(tempo)
    return (string.format("%.6f", round6(tempo)):gsub("0+$", ""):gsub("%.$", ""))
end

local function key_micro(key)
    return tonumber(tostring(key):match("^t(%-?%d+)$"))
end

-- One usable row's targets, in its own planned order, as the keys of the passes
-- that actually render it. A target the multiplier merges into another tempo's
-- pass takes that pass's key (the GFX script renders it there). Targets at or
-- below 0 BPM, and several passes sharing one file suffix, are left out.
-- Eligibility is per pass (row.allowed[group]), never per public key: passes
-- with different file suffixes can share one rounded key.
local function assign_targets(plan, row, multiplier, group_by_music_key)
    local _, own = plan_lib.build_per_region_queue_groups({ setmetatable({}, { __index = row }) }, multiplier)
    local order, seen_group, groups_of_suffix, suffixes = {}, {}, {}, {}
    local nonpositive, merged = false, {}
    for _, step in ipairs(own) do
        local group = group_by_music_key[plan_lib.music_group_key(step.base_actual, step.target_actual, step.tempo_display)]
        if not group then
            error("A planned tempo has no render pass.", 0) -- the builder ran over this row; cannot happen
        elseif step.target_tempo <= 0 or group.target_tempo <= 0 or key_micro(group.key) <= 0 then
            nonpositive = true
        else
            if group.key ~= tempo_key(step.target_tempo) then
                merged[#merged + 1] = bpm_text(step.target_tempo) .. " is rendered as " .. bpm_text(group.target_tempo)
            end
            if not seen_group[group] then
                seen_group[group] = true
                order[#order + 1] = group
            end
            local suffix = group.tempo_display
            if not groups_of_suffix[suffix] then
                groups_of_suffix[suffix] = {}
                suffixes[#suffixes + 1] = suffix
            end
            groups_of_suffix[suffix][group] = true
        end
    end
    if nonpositive then
        row.notes[#row.notes + 1] = "Tempos at or below 0 BPM are not planned."
        plan.issues[#plan.issues + 1] = string.format(
            "Region %s has saved tempos at or below 0 BPM; those tempos were left out.", row.name)
    end
    if #merged > 0 then
        plan.issues[#plan.issues + 1] = string.format(
            "Region %s: with the tempo multiplier, %s, because they are the same tempo.", row.name, table.concat(merged, ", "))
    end
    local removed = {}
    for _, suffix in ipairs(suffixes) do
        local count = 0
        for _ in pairs(groups_of_suffix[suffix]) do count = count + 1 end
        if count > 1 then
            removed[suffix] = true
            plan.issues[#plan.issues + 1] = string.format(
                "Region %s has several tempos that round to the same file suffix %s; those tempos were left out.",
                row.name, suffix)
        end
    end
    row.allowed = {}
    local listed = {}
    for _, group in ipairs(order) do
        if not removed[group.tempo_display] then
            row.allowed[group] = true
            if not listed[group.key] then
                listed[group.key] = true
                row.public.targets[#row.public.targets + 1] = group.key
            end
        end
    end
end

-- Builds the public plan and the internal rows/groups render needs.
local function build(api)
    local proj, path = api.EnumProjects(-1, "")
    if not proj then
        return new_plan("no_project", "No project is open in REAPER.")
    end
    local helpers = dofile(directory .. "tempo_set_project.lua").new(api)
    local plan = new_plan("ready", "")
    path = path or ""
    local internal = { proj = proj, path = path, helpers = helpers, rows = {}, by_id = {}, groups = {} }
    plan._internal = internal
    if path == "" then
        plan.status, plan.message = "unsaved", "Save the project in REAPER before re-rendering tempos."
        return plan
    end
    plan.project = { name = project_basename(path), id = fnv1a(path) }

    local multiplier = read_multiplier(api, proj)
    local _, audio_flag = ext_state(api, proj, plan_lib.AUDIO_CHECK_OPTION_KEY)
    local _, blob = ext_state(api, proj, plan_lib.SAVED_REGION_ROWS_KEY)
    plan.multiplier = multiplier
    plan.audio_check = audio_flag ~= "0"
    plan.preset_ready = helpers.resolve_command(plan_lib.CMD_APPLY_GPHIL_RENDER) ~= nil
    internal.blob, internal.audio_flag, internal.multiplier = blob, audio_flag, multiplier
    if not plan.preset_ready then
        plan.issues[#plan.issues + 1] = "The GPHIL_RENDER render preset action is not installed."
    end

    if blob == "" then
        plan.status, plan.message = "missing", "No saved Tempo Set settings. Open the Tempo Set grid in REAPER and press Save."
        return plan
    end
    if not (multiplier > 0) then
        plan.status, plan.message = "invalid", "The saved tempo multiplier must be greater than zero."
        return plan
    end
    local saved_rows = plan_lib.deserialize_region_rows(blob)
    if #saved_rows == 0 then
        plan.status, plan.message = "invalid", "The saved Tempo Set settings could not be read."
        return plan
    end

    -- Match saved rows to current regions with the grid's Load identity.
    local saved_by_key, saved_count = {}, {}
    for _, row in ipairs(saved_rows) do
        local key = plan_lib.row_storage_key(row)
        saved_count[key] = (saved_count[key] or 0) + 1
        saved_by_key[key] = row
    end
    local regions = helpers.collect_regions_with_handles(proj)
    table.sort(regions, function(a, b)
        if a.pos ~= b.pos then return a.pos < b.pos end
        return a.internal_index < b.internal_index
    end)
    local current_count = {}
    for _, region in ipairs(regions) do
        local key = plan_lib.row_storage_key(region)
        current_count[key] = (current_count[key] or 0) + 1
    end
    local matched_keys, matched, reported = {}, {}, {}
    for _, region in ipairs(regions) do
        local key = plan_lib.row_storage_key(region)
        local saved = saved_by_key[key]
        if saved then
            matched_keys[key] = true
            if saved_count[key] > 1 or current_count[key] > 1 then
                if not reported[key] then
                    reported[key] = true
                    plan.issues[#plan.issues + 1] = string.format(
                        "Region %s is ambiguous (several saved rows or regions share its number, position and name); it was left out.",
                        region.name)
                end
            else
                matched[#matched + 1] = { region = region, saved = saved, key = key }
            end
        end
    end
    for _, row in ipairs(saved_rows) do
        local key = plan_lib.row_storage_key(row)
        if not matched_keys[key] then
            plan.issues[#plan.issues + 1] = string.format(
                "Saved row %s no longer matches a region in the project; it was left out.", row.name)
        end
    end
    if #matched == 0 then
        plan.status, plan.message = "stale", "The saved Tempo Set settings do not match any current region. Open the grid, Load, and Save again."
        return plan
    end

    -- $region names the output files, so count every current region, saved or not.
    -- One name that cannot be compared could share a file with any other name.
    local name_count, uncomparable = {}, nil
    for _, region in ipairs(regions) do
        local name = output_name(region.name)
        if name then
            name_count[name] = (name_count[name] or 0) + 1
        else
            uncomparable = uncomparable or region.name
        end
    end
    if uncomparable then
        plan.issues[#plan.issues + 1] = string.format("Region %s has a name with characters GPhilDeck cannot compare "
            .. "with other region names, so no region is re-rendered from GPhilDeck. Rename it, or use the Tempo Set window.",
            uncomparable)
    end

    local revision_parts = {
        "contract=" .. M.CONTRACT, "path=" .. path, "blob=" .. blob,
        "multiplier=" .. string.format("%.17g", multiplier), "audio=" .. (plan.audio_check and "1" or "0"),
        "preset=" .. plan_lib.CMD_APPLY_GPHIL_RENDER, "pattern=" .. plan_lib.RENDER_PATTERN_BASE
    }
    local configs = {}
    for _, entry in ipairs(matched) do
        local region, saved = entry.region, entry.saved
        local detected = api.TimeMap2_GetDividedBpmAtTime(proj, region.pos) / multiplier
        revision_parts[#revision_parts + 1] = "row=" .. entry.key .. "\t" .. string.format("%.9f", detected)
        local row = {
            id = fnv1a(entry.key), key = entry.key, internal_index = region.internal_index,
            pos = region.pos, rgnend = region.rgnend, name = region.name, number = region.number,
            base_tempo = detected, start_tempo = saved.start_tempo, step = saved.step,
            end_tempo = saved.end_tempo, render_click = false, enabled = saved.enabled ~= false
        }
        local public = {
            id = row.id, name = row.name, number = as_integer(row.number), base = detected,
            saved_base = saved.base_tempo, min = row.start_tempo, max = row.end_tempo, step = row.step,
            enabled = row.enabled, targets = {}
        }
        local notes = {}
        if math.abs(saved.base_tempo - detected) > 1e-6 then
            notes[#notes + 1] = string.format("Saved Base %g differs from the detected Base %g; the detected Base is used.",
                saved.base_tempo, round6(detected))
        end
        local valid, reason = plan_lib.validate_row(row)
        if valid and plan_lib.row_iteration_count(row) > plan_lib.MAX_ROW_ITERATIONS then
            valid, reason = false, "More than " .. plan_lib.MAX_ROW_ITERATIONS .. " tempos"
        end
        local usable = row.enabled
        if not row.enabled then
            notes[#notes + 1] = "Turned off in the saved settings; not re-rendered."
            plan.issues[#plan.issues + 1] = string.format("Region %s is turned off in the saved settings.", row.name)
        elseif not valid then
            usable = false
            notes[#notes + 1] = "Not planned: " .. reason .. "."
            plan.issues[#plan.issues + 1] = string.format("Region %s has invalid saved settings (%s); it was left out.", row.name, reason)
        elseif uncomparable then
            usable = false
            notes[#notes + 1] = "Not planned: region " .. uncomparable .. " has a name GPhilDeck cannot compare safely."
        elseif name_count[output_name(row.name)] > 1 then
            usable = false
            notes[#notes + 1] = "Another region has the same name, so their output files would collide."
            plan.issues[#plan.issues + 1] = string.format("Regions named %s share an output name; they were left out.", row.name)
        end
        row.public, row.notes = public, notes
        plan.regions[#plan.regions + 1] = public
        internal.rows[#internal.rows + 1] = row
        internal.by_id[row.id] = row
        if usable then configs[#configs + 1] = row end
    end

    -- The real scheduled passes, from the existing group builder over all usable rows.
    local _, groups = plan_lib.build_per_region_queue_groups(configs, multiplier)
    local group_by_music_key = {}
    for _, group in ipairs(groups) do
        group.key = tempo_key(group.target_tempo)
        group_by_music_key[plan_lib.music_group_key(group.base_actual, group.target_actual, group.tempo_display)] = group
    end
    for _, row in ipairs(configs) do
        assign_targets(plan, row, multiplier, group_by_music_key)
    end
    for _, row in ipairs(internal.rows) do
        if #row.notes > 0 then row.public.note = table.concat(row.notes, " ") end
        row.notes = nil
    end

    -- Each pass keeps only the rows allowed in that very pass, so plan.tempos and
    -- every region's targets list exactly the same keys, and a press renders only
    -- passes the plan marked eligible.
    local tempo_by_key = {}
    for _, group in ipairs(groups) do
        local key, kept, seen = group.key, {}, {}
        for _, row in ipairs(group.regions) do
            if row.allowed and row.allowed[group] and not seen[row] then
                seen[row] = true
                kept[#kept + 1] = row
            end
        end
        if #kept > 0 then
            group.rows = kept
            internal.groups[#internal.groups + 1] = group
            local entry = tempo_by_key[key]
            if not entry then
                entry = { key = key, tempo = group.target_tempo, label = string.format("%g", round6(group.target_tempo)),
                    suffix = plan_lib.tempo_suffix_value(group.target_tempo), regions = {}, passes = 0, members = {} }
                tempo_by_key[key] = entry
                plan.tempos[#plan.tempos + 1] = entry
            end
            entry.passes = entry.passes + 1
            for _, row in ipairs(kept) do entry.members[row.id] = true end
        end
    end
    for _, entry in ipairs(plan.tempos) do
        for _, row in ipairs(internal.rows) do
            if entry.members[row.id] then entry.regions[#entry.regions + 1] = row.id end
        end
        entry.members = nil
    end

    if #plan.tempos == 0 then
        plan.status, plan.message = "invalid", "No region in the saved Tempo Set settings has a tempo that can be re-rendered."
        return plan
    end
    plan.revision = fnv1a(table.concat(revision_parts, "\n"))
    plan.message = string.format("%d region(s), %d tempo(s) ready to re-render.", #plan.regions, #plan.tempos)
    return plan
end

local function public_plan(plan)
    plan._internal = nil
    return plan
end

function M.plan(api)
    return public_plan(build(api))
end

local function find_by(list, field, value)
    for _, entry in ipairs(list or {}) do
        if entry[field] == value then return entry end
    end
end

-- Render step 1: every check before any effect. Returns message or nil, plus the plan.
local function check_request(api, request)
    if type(request) ~= "table" or request.contract ~= M.CONTRACT then
        return "This re-render request uses a different Tempo Set version. Update GPhil REAPER scripts."
    end
    local plan = build(api)
    if plan.status == "no_project" or plan.status == "unsaved" then return plan.message end
    if plan.project.id ~= request.project then
        return "A different project is open in REAPER. Reload the plan."
    end
    if plan.status ~= "ready" then return plan.message end
    if request.revision ~= plan.revision then
        return "The Tempo Set plan changed in REAPER. Reload the plan and try again."
    end
    local micro = key_micro(request.tempo)
    if micro and micro <= 0 then return "Tempos must be greater than 0 BPM." end
    local tempo = find_by(plan.tempos, "key", request.tempo)
    if not tempo or not (tempo.tempo > 0) then return "That tempo is no longer in the saved plan." end
    if request.scope == "region" then
        local listed = false
        for _, id in ipairs(tempo.regions) do listed = listed or id == request.region end
        if not listed then return "That region is not planned at that tempo." end
    elseif request.scope ~= "tempo" then
        return "Unknown re-render scope."
    end
    if request.audio_check ~= plan.audio_check then
        return "The audio check setting changed in REAPER. Reload the plan."
    end
    if not plan.preset_ready then
        return "The GPHIL_RENDER render preset action is not installed in REAPER."
    end
    local supported, reason = render_pass.preflight(api)
    if not supported then return reason end
    if api.GetAllProjectPlayStates(0) ~= 0 then
        return "Stop playback and recording in REAPER before re-rendering."
    end
    if request.replace ~= M.REPLACE_POLICY then
        return "Unknown replacement policy."
    end
    if type(request.run) ~= "string" or not request.run:match("^%x+$") then
        return "The re-render run identifier is not valid."
    end
    return nil, plan
end

function M.validate(api, request)
    local ok, message = pcall(check_request, api, request)
    if not ok then return "Could not check the request: " .. tostring(message) end
    return message
end

-- Groups for the requested scope, in existing group order, limited to scoped rows.
local function scoped_passes(plan, request)
    local passes = {}
    local tempo = find_by(plan.tempos, "key", request.tempo)
    local wanted = {}
    for _, id in ipairs(tempo.regions) do
        if request.scope == "tempo" or id == request.region then wanted[id] = true end
    end
    for _, group in ipairs(plan._internal.groups) do
        if group.key == request.tempo then
            local rows = {}
            for _, row in ipairs(group.rows) do
                if wanted[row.id] then rows[#rows + 1] = row end
            end
            if #rows > 0 then passes[#passes + 1] = { group = group, rows = rows } end
        end
    end
    return passes, tempo
end

local function split_targets(text)
    local list = {}
    for part in (text or ""):gmatch("[^;]+") do list[#list + 1] = part end
    return list
end

-- The shared lookup finds one track whose lowercase name contains "clicktrack".
-- Music passes also mute every track whose name, lowercased with everything but
-- letters and digits removed, contains "clicktrack" (for example "CLICK TRACK").
local function find_click_tracks(api, proj, shared)
    local list = {}
    for i = 0, api.CountTracks(proj) - 1 do
        local track = api.GetTrack(proj, i)
        local _, name = api.GetTrackName(track, "")
        local compact = (tostring(name or ""):lower():gsub("[^%w]", ""))
        if track == shared or compact:find("clicktrack", 1, true) then
            list[#list + 1] = { track = track, mute = api.GetMediaTrackInfo_Value(track, "B_MUTE") }
        end
    end
    return list
end

-- The shared restore ignores setter results; read every captured render setting
-- back and add one restore error per setting that did not return.
local function verify_render_state(api, proj, state, errors)
    if not state then return end
    local function mismatch(key)
        errors[#errors + 1] = "render settings: " .. key .. " did not return to its original value."
    end
    for _, key in ipairs(plan_lib.RENDER_NUMERIC_KEYS) do
        local want = state.numeric[key]
        if want ~= nil then
            local read_ok, got = pcall(api.GetSetProjectInfo, proj, key, 0, false)
            if not read_ok or type(got) ~= "number" or math.abs(got - want) > 1e-9 * math.max(1, math.abs(want)) then
                mismatch(key)
            end
        end
    end
    for _, key in ipairs(plan_lib.RENDER_STRING_KEYS) do
        local want = state.strings[key]
        if want ~= nil then
            local read_ok, found, got = pcall(api.GetSetProjectInfo_String, proj, key, "", false)
            if not read_ok or not found or got ~= want then mismatch(key) end
        end
    end
end

local function result_table(state, message, extra)
    local result = { state = state, message = message, passes_completed = 0, passes = 0, outputs = {},
        restored = true, restore_errors = {} }
    for key, value in pairs(extra or {}) do result[key] = value end
    return result
end

function M.render(api, request, report)
    local function emit(event)
        if type(report) == "function" then pcall(report, event) end
    end
    local checked, rejection, plan = pcall(check_request, api, request)
    if not checked then return result_table("rejected", "Could not check the request: " .. tostring(rejection)) end
    if rejection then return result_table("rejected", rejection) end

    local internal, multiplier = plan._internal, plan.multiplier
    local proj, path, helpers = internal.proj, internal.path, internal.helpers
    local passes, tempo = scoped_passes(plan, request)
    local tempo_map = dofile(directory .. "tempo_map.lua").new(api)

    local original_map, original_render, original_selection
    local captured, capture_error = pcall(function()
        original_map = tempo_map.capture(proj)
        original_render = helpers.capture_render_state(proj)
        original_selection = helpers.capture_region_selection(proj)
    end)
    if not captured then
        return result_table("rejected", "Nothing was rendered: " .. tostring(capture_error), { passes = #passes })
    end

    local click_tracks = find_click_tracks(api, proj, helpers.find_click_track(proj))
    local solo_track = helpers.find_solo_track(proj)
    local original_solo_mute = solo_track and api.GetMediaTrackInfo_Value(solo_track, "B_MUTE")
    local previous_tracks = {}
    for i = 0, api.CountTracks(proj) - 1 do
        local track = api.GetTrack(proj, i)
        if api.IsTrackSelected(track) then previous_tracks[#previous_tracks + 1] = track end
    end

    -- Same restoration steps, in the same order, as the GFX script.
    local cleanup = render_session.new()
    cleanup.add("tempo and meter map", function() tempo_map.restore(proj, original_map) end)
    cleanup.add("render settings", function() helpers.restore_render_state(proj, original_render) end)
    cleanup.add("region selection", function() helpers.restore_region_selection(proj, original_selection) end)
    cleanup.add("track mutes", function()
        for _, click in ipairs(click_tracks) do
            if api.ValidatePtr2(proj, click.track, "MediaTrack*") then
                api.SetMediaTrackInfo_Value(click.track, "B_MUTE", click.mute)
            end
        end
        if solo_track and original_solo_mute ~= nil and api.ValidatePtr2(proj, solo_track, "MediaTrack*") then
            api.SetMediaTrackInfo_Value(solo_track, "B_MUTE", original_solo_mute)
        end
    end)
    cleanup.add("track selection", function()
        for i = 0, api.CountTracks(proj) - 1 do
            api.SetTrackSelected(api.GetTrack(proj, i), false)
        end
        for _, track in ipairs(previous_tracks) do
            if api.ValidatePtr2(proj, track, "MediaTrack*") then api.SetTrackSelected(track, true) end
        end
    end)
    local undo_open = false
    cleanup.add("undo block", function()
        if undo_open then
            undo_open = false
            api.Undo_EndBlock2(proj, "renderTempoSet - " .. CHECKPOINT_TITLE_LABEL, -1)
        end
    end)
    cleanup.add("arrange refresh", function() api.UpdateArrange() end)
    if api.atexit then api.atexit(function() cleanup.finish() end) end

    local state = { completed = 0, outputs = {}, declined = false, context_error = nil }
    -- manifests: the run folders this render created (never a pre-existing one).
    local work_dirs, manifests, run_dir, stage_dir, previous_dir, previous_used, staged_kept = {}, {}
    local stop_reason, rollback_incomplete

    local function require_context()
        local active, active_path = api.EnumProjects(-1, "")
        local message
        if active ~= proj or (active_path or "") ~= path then
            message = "The active project changed in REAPER; the re-render stopped."
        else
            local _, blob = ext_state(api, proj, plan_lib.SAVED_REGION_ROWS_KEY)
            local _, audio_flag = ext_state(api, proj, plan_lib.AUDIO_CHECK_OPTION_KEY)
            if blob ~= internal.blob or audio_flag ~= internal.audio_flag
                or read_multiplier(api, proj) ~= internal.multiplier then
                message = "The saved Tempo Set settings changed in REAPER; the re-render stopped."
            end
        end
        if message then
            state.context_error = message
            error(message, 0)
        end
    end

    -- Finds each scoped row's region by identity again (positions within 1 microsecond).
    local function locate(rows)
        local found = {}
        local current = helpers.collect_regions_with_handles(proj)
        for _, row in ipairs(rows) do
            local hit
            for _, region in ipairs(current) do
                if region.number == row.number and region.name:lower() == row.name:lower()
                    and math.abs(region.pos - row.pos) < 1e-6 and math.abs(region.rgnend - row.rgnend) < 1e-6 then
                    if hit then hit = false break end
                    hit = region
                end
            end
            if not hit then
                state.context_error = "Region " .. row.name .. " changed in REAPER; the re-render stopped."
                error(state.context_error, 0)
            end
            found[#found + 1] = { row = row, internal_index = hit.internal_index }
        end
        return found
    end

    local current_pass_index = 0
    -- The existing checkpoint, announced to Deck first. Only a "No" answer is a cancel.
    local function review(reaper_api, context)
        if context.enabled ~= false and context.kind == "music" then
            emit({ state = "awaiting_audio_check", pass = current_pass_index, passes = #passes,
                label = context.label, message = "Check the rendered audio in REAPER, then answer the dialog." })
        end
        local ok, reason = audio_checkpoint.review(reaper_api, context)
        if not ok and tostring(reason):find("^Stopped at the audio quality checkpoint") then state.declined = true end
        return ok, reason
    end
    local submit = render_submission.new(api, proj, {
        render_now = true,
        queue_options = { skip_existing = true, pause_audio_check = plan.audio_check },
        render_pass = render_pass,
        audio_checkpoint = { review = review },
        remove_file = function() return nil, "the re-render never deletes outputs" end,
        require_original_project = require_context,
        log = function() end,
        stop = function(reason)
            stop_reason = reason
            error(reason, 0)
        end
    })

    local ok, err = pcall(function()
        api.Undo_BeginBlock2(proj)
        undo_open = true
        if solo_track then api.SetMediaTrackInfo_Value(solo_track, "B_MUTE", 1) end
        api.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 5, true)
        for pass_index, pass in ipairs(passes) do
            current_pass_index = pass_index
            require_context()
            local group = pass.group
            local names = {}
            for _, row in ipairs(pass.rows) do names[#names + 1] = row.name end
            local label = table.concat(names, ", ") .. " · " .. tempo.label
            emit({ state = "rendering", pass = pass_index, passes = #passes, label = label,
                message = "Rendering " .. label .. "." })

            -- The GFX script's per-pass sequence for one music group.
            tempo_map.restore(proj, original_map)
            local live = locate(pass.rows)
            -- Scope intentionally limits new base markers to the requested rows.
            for _, row in ipairs(pass.rows) do
                tempo_map.ensure(proj, row.pos, row.base_tempo * multiplier, true)
            end
            local markers_for_scale = tempo_map.capture(proj)
            tempo_map.scale(proj, markers_for_scale, group.factor)
            for _, item in ipairs(live) do
                local region = api.GetRegionOrMarker(proj, item.internal_index, "")
                if not region then error("A requested region no longer exists.", 0) end
                local live_start = api.GetRegionOrMarkerInfo_Value(proj, region, "D_STARTPOS")
                tempo_map.ensure(proj, live_start, group.target_actual, true)
            end
            for _, click in ipairs(click_tracks) do
                api.SetMediaTrackInfo_Value(click.track, "B_MUTE", 1)
            end
            helpers.restore_render_state(proj, original_render)
            local command = helpers.resolve_command(plan_lib.CMD_APPLY_GPHIL_RENDER)
            if not command then error("The GPHIL_RENDER render preset action is not installed.", 0) end
            api.Main_OnCommand(command, 0)
            local pattern = plan_lib.with_tempo_suffix(plan_lib.RENDER_PATTERN_BASE, group.tempo_display)
            helpers.set_render_pattern(proj, pattern)
            helpers.select_regions(proj, live)
            api.GetSetProjectInfo(proj, "RENDER_BOUNDSFLAG", 5, true)
            tempo_map.commit()

            -- Staged replacement: render beside the outputs, never over them.
            if api.GetSetProjectInfo(proj, "RENDER_ADDTOPROJ", 0, false) ~= 0 then
                error("The render preset adds renders to the project; re-rendering refuses to change project tracks.", 0)
            end
            local root = helpers.get_render_directory(proj)
            if root == "" then error("Could not find the render folder.", 0) end
            local _, canonical_text = api.GetSetProjectInfo_String(proj, "RENDER_TARGETS", "", false)
            local canonical = split_targets(canonical_text)
            if #canonical == 0 then error("No render output files were found; nothing was rendered.", 0) end
            local rels, rel_error = staging.relative(root, canonical, M.WORK_FOLDER)
            if not rels then error(rel_error, 0) end
            local work = slash(root):gsub("/+$", "") .. "/" .. M.WORK_FOLDER
            run_dir = work .. "/" .. request.run
            stage_dir, previous_dir = run_dir .. "/stage", run_dir .. "/previous"
            local manifest = run_dir .. "/manifest.txt"
            if not manifests[manifest] then
                local created, create_error = staging.create(api, run_dir, manifest, M._fs.time())
                if not created then error(create_error, 0) end
                manifests[manifest] = true
                work_dirs[work] = true
            end
            api.GetSetProjectInfo_String(proj, "RENDER_FILE", stage_dir, true)
            local _, staged_text = api.GetSetProjectInfo_String(proj, "RENDER_TARGETS", "", false)
            local staged = split_targets(staged_text)
            local staged_rels, staged_error = staging.relative(stage_dir, staged, M.WORK_FOLDER)
            if not staged_rels or #staged_rels ~= #rels then
                error(staged_error or "Staged outputs do not match the real outputs; nothing was rendered.", 0)
            end
            local entries = {}
            for i, rel in ipairs(rels) do
                if staged_rels[i] ~= rel then
                    error("Staged outputs do not match the real outputs; nothing was rendered.", 0)
                end
                if api.file_exists(staged[i]) then
                    error("A staged output already exists: " .. staged[i], 0)
                end
                entries[i] = { rel = rel, canonical = canonical[i], staged = staged[i],
                    previous = previous_dir .. "/" .. rel }
                local noted, note_error = staging.manifest(manifest, "stage", rel)
                if not noted then error(note_error, 0) end
            end

            staged_kept = true
            submit("music", label, pattern)

            emit({ state = "replacing", pass = pass_index, passes = #passes, label = label,
                message = "Replacing the old files for " .. label .. "." })
            local swapped, swap_error, incomplete = staging.swap(api, entries, manifest)
            for _, entry in ipairs(entries) do
                if entry.backed_up then previous_used = true end
            end
            if not swapped then
                rollback_incomplete = incomplete
                error(swap_error, 0)
            end
            staged_kept = false
            for _, entry in ipairs(entries) do
                state.outputs[#state.outputs + 1] = entry.rel
            end
            state.completed = pass_index
            api.UpdateArrange()
        end
    end)

    local restore_errors = cleanup.finish()
    pcall(verify_render_state, api, proj, original_render, restore_errors)
    local final_state, message
    -- Mark the run prunable with one final line: "done" when it finished, or
    -- "discardable" when it stopped with nothing left in previous/ (no backup, or
    -- every backup moved back). Otherwise it stays unmarked and is kept. Then
    -- prune older marked runs.
    local marker = ok and "done" or ((not rollback_incomplete and not previous_used) and "discardable" or nil)
    if marker then
        for manifest in pairs(manifests) do pcall(staging.manifest, manifest, marker, tostring(M._fs.time())) end
        for work in pairs(work_dirs) do pcall(staging.prune, api, work, request.run, M.KEEP_OTHER_RUNS) end
    end
    if ok then
        final_state = "completed"
        message = string.format("Re-rendered %s: %d file(s) replaced. This is not an audio-quality verdict.",
            tempo.label, #state.outputs)
    else
        message = tostring(stop_reason or err)
        final_state = state.declined and "canceled" or "failed"
        if state.completed > 0 then
            message = message .. string.format(" Pass(es) already replaced: %d.", state.completed)
        end
        if not rollback_incomplete then
            message = message .. " Old outputs for the stopped pass were not changed."
        end
    end
    return result_table(final_state, message, {
        passes_completed = state.completed, passes = #passes, outputs = state.outputs,
        previous_dir = previous_used and previous_dir or nil,
        staged_dir = (not ok and staged_kept) and stage_dir or nil,
        restored = #restore_errors == 0, restore_errors = restore_errors
    })
end

return M
