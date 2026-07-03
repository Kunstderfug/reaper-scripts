-- GPhil_createStemTrackStructure.lua
-- Create a standard stem folder/child track structure.
--
-- Section tracks are render bus folders. Stem tracks are single child tracks
-- under their section or root group, using abbreviation names so $folders can
-- produce concise render filenames.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper
---@diagnostic disable-next-line: undefined-global
local gfx = gfx

local EXT_SECTION = "GPhilCreateStemTrackStructure"
local SCRIPT_TITLE = "Create Stem Track Structure"
local GLOBAL_FOLDER_NAME = "STEMS"

local FX_CHAIN_DIR = "/Volumes/PROJECTS/PROJECTS_IN_WORK/REAPER_PROJECTS/G-PHIL/FXChains/GPHIL"

local FX_CHAIN_BY_CODE = {
    w = "GPHIL_STEM_W.RfxChain",
    b = "GPHIL_STEM_B.RfxChain",
    p = "GPHIL_STEM_P.RfxChain",
    s = "GPHIL_STEM_S.RfxChain",
    band = "GPHIL_STEM_BAND.RfxChain",
}

-- Optional extra FX/plugin/action to apply after the automatic GPhil chains.
local DEFAULT_EXTRA_FX = ""
local saved_selected_tracks = nil
local current_color_map = nil

local function node(code, display_name, children)
    children = children or {}
    children.code = code
    children.name = code
    children.display_name = display_name
    return children
end

local ROOT_GROUPS = {
    node("orch", "Orchestra", {
        sections = {
            node("w", "Woodwinds", {
                stems = {
                    node("fl", "Flutes"),
                    node("ob", "Oboes"),
                    node("cl", "Clarinets"),
                    node("bsn", "Bassoons"),
                },
            }),
            node("b", "Brass", {
                stems = {
                    node("hn", "Horns"),
                    node("tr", "Trumpets"),
                    node("tn", "Trombones"),
                    node("tb", "Tuba"),
                },
            }),
            node("p", "Percussion", {
                stems = {
                    node("ti", "Timpani"),
                    node("sd", "Snare Drum"),
                    node("bd", "Bass Drum"),
                    node("cy", "Cymbals"),
                    node("pi", "Piano"),
                },
            }),
            node("s", "Strings", {
                stems = {
                    node("vln1", "Violin1"),
                    node("vln2", "Violin2"),
                    node("vla", "Viola"),
                    node("vc", "Cello"),
                    node("db", "DoubleBasses"),
                },
            }),
        },
    }),
    node("band", "Band", {
        stems = {
            node("sx", "Saxophones"),
            node("lg", "Lead Guitar"),
            node("bg", "Bass Guitar"),
            node("dr", "Drums"),
            node("ab", "A. Bass"),
        },
    }),
}

local CODE_ALIASES = {
    sn = "sd",
}

local function msg(text)
    reaper.ShowMessageBox(tostring(text), SCRIPT_TITLE, 0)
end

local function trim(s)
    return (s or ""):match("^%s*(.-)%s*$")
end

local function split_codes(values)
    local out = {}
    local normalized = tostring(values or ""):gsub("[,;|]", " ")
    for value in normalized:gmatch("%S+") do
        out[#out + 1] = trim(value)
    end
    return out
end

local function bool_from_text(value)
    local s = trim(value):lower()
    return s == "y" or s == "yes" or s == "1" or s == "true"
end

local function clamp(value, min_value, max_value)
    if value < min_value then
        return min_value
    end
    if value > max_value then
        return max_value
    end
    return value
end

local function random_color_entry()
    local r = math.random(70, 220)
    local g = math.random(70, 220)
    local b = math.random(70, 220)
    return {
        r = r,
        g = g,
        b = b,
        color = reaper.ColorToNative(r, g, b) + 0x1000000,
    }
end

local function vary_color_entry(entry)
    local r = clamp(entry.r + math.random(-18, 18), 45, 235)
    local g = clamp(entry.g + math.random(-18, 18), 45, 235)
    local b = clamp(entry.b + math.random(-18, 18), 45, 235)
    return reaper.ColorToNative(r, g, b) + 0x1000000
end

local function set_track_color(track, color)
    if color then
        reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", color)
    end
end

local function create_color_map()
    math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000000))

    local map = {
        global = random_color_entry(),
    }

    for _, root in ipairs(ROOT_GROUPS) do
        map[root.code] = random_color_entry()
        for _, section in ipairs(root.sections or {}) do
            map[section.code] = random_color_entry()
        end
    end

    return map
end

local function escape_pattern(text)
    return tostring(text):gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local content = f:read("*a")
    f:close()
    return content
end

local function get_chain_path(chain_file)
    return FX_CHAIN_DIR .. "/" .. chain_file
end

local function load_chain_chunk(chain_file)
    local path = get_chain_path(chain_file)
    local content = read_file(path)
    if not content or trim(content) == "" then
        return nil, path
    end
    return trim(content), path
end

local function update_track_main_fx_chain_chunk(track_chunk, fx_chain_chunk, append)
    local fx_chunk =
        track_chunk:match("(<FXCHAIN.-DOCKED%s%d)\n>")
        or track_chunk:match("<FXCHAIN\n.-(BYPASS.-)\n<FXCHAIN_REC")
        or track_chunk:match("<FXCHAIN\n.-(BYPASS.-)\n<ITEM")
        or track_chunk:match("<FXCHAIN\n.-(BYPASS.-)\n>\n$")
        or track_chunk:match("(<TRACK.-)\n<FXCHAIN_REC")
        or track_chunk:match("(<TRACK.-)\n<ITEM")
        or track_chunk:match("(<TRACK.-)\n>\n<TRACK")
        or track_chunk:match("(<TRACK.-)\n>")

    if not fx_chunk then
        return nil
    end

    local replacement
    if append and fx_chunk:match("BYPASS") then
        local existing = fx_chunk:match("(BYPASS.*WAK[%s%d]*)[\n>]*")
        replacement = (existing or "") .. "\n" .. fx_chain_chunk .. "\n>"
    elseif fx_chunk:match("BYPASS") then
        replacement = fx_chain_chunk .. "\n>"
    elseif fx_chunk:match("FXCHAIN") then
        replacement = fx_chunk .. "\n" .. fx_chain_chunk
    else
        replacement = fx_chunk .. "\n<FXCHAIN\n" .. fx_chain_chunk .. "\n>"
    end

    return track_chunk:gsub(escape_pattern(fx_chunk), replacement:gsub("%%", "%%%%"), 1)
end

local function append_fx_chain_to_track(track, chain_file)
    local chain_chunk, path = load_chain_chunk(chain_file)
    if not chain_chunk then
        return false, "Missing or empty FX chain:\n" .. path
    end

    local ok, track_chunk = reaper.GetTrackStateChunk(track, "", false)
    if not ok or not track_chunk then
        return false, "Could not read track state while loading:\n" .. path
    end

    local has_fx = reaper.TrackFX_GetCount(track) > 0
    local updated_chunk = update_track_main_fx_chain_chunk(track_chunk, chain_chunk, has_fx)
    if not updated_chunk then
        return false, "Could not update track FX chunk while loading:\n" .. path
    end

    if not reaper.SetTrackStateChunk(track, updated_chunk, false) then
        return false, "Could not write track FX chunk while loading:\n" .. path
    end

    return true
end

local function find_track_by_name(proj, wanted_name)
    local wanted = (wanted_name or ""):lower()
    for i = 0, reaper.CountTracks(proj) - 1 do
        local track = reaper.GetTrack(proj, i)
        local _, name = reaper.GetTrackName(track, "")
        if (name or ""):lower() == wanted then
            return track
        end
    end
    return nil
end

local function set_track_name(track, name)
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
end

local function insert_track_at_end(proj, name)
    local index = reaper.CountTracks(proj)
    reaper.InsertTrackAtIndex(index, true)
    local track = reaper.GetTrack(proj, index)
    set_track_name(track, name)
    return track
end

local function add_fx_to_track(track, fx_name)
    fx_name = trim(fx_name)
    if fx_name == "" then
        return true
    end

    local explicit_action_id = fx_name:match("^action:(.+)$")
    local action_id = explicit_action_id or fx_name
    local command = nil
    if action_id:match("^_") then
        command = reaper.NamedCommandLookup(action_id)
    elseif action_id:match("^%d+$") then
        command = tonumber(action_id)
    end

    if command and command ~= 0 then
        reaper.SetOnlyTrackSelected(track)
        reaper.Main_OnCommand(command, 0)
        return true
    end
    if explicit_action_id then
        return false
    end

    local index = reaper.TrackFX_AddByName(track, fx_name, false, -1)
    return index and index >= 0
end

local function apply_chain_files(track, chain_files)
    for _, chain_file in ipairs(chain_files or {}) do
        if not file_exists(get_chain_path(chain_file)) then
            goto continue
        end

        local ok, err = append_fx_chain_to_track(track, chain_file)
        if not ok then
            return false, err
        end

        ::continue::
    end
    return true
end

local function save_selected_tracks(proj)
    local selected = {}
    for i = 0, reaper.CountSelectedTracks(proj) - 1 do
        selected[#selected + 1] = reaper.GetSelectedTrack(proj, i)
    end
    return selected
end

local function restore_selected_tracks(proj, selected)
    reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
    for _, track in ipairs(selected or {}) do
        if reaper.ValidatePtr2(proj, track, "MediaTrack*") then
            reaper.SetTrackSelected(track, true)
        end
    end
end

local function close_folder_on_last_created_track(proj, global_folder_track)
    if not global_folder_track then
        return
    end

    local last_track = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
    if not last_track or last_track == global_folder_track then
        return
    end

    local depth = reaper.GetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", depth - 1)
end

local function create_global_folder(proj)
    local track = insert_track_at_end(proj, GLOBAL_FOLDER_NAME)
    reaper.SetMediaTrackInfo_Value(track, "I_FOLDERDEPTH", 1)
    set_track_color(track, current_color_map and current_color_map.global.color)
    return track
end

local function create_stem_track(proj, stem, chain_files, extra_fx, color_entry)
    local stem_track = insert_track_at_end(proj, stem.name)
    reaper.SetMediaTrackInfo_Value(stem_track, "I_FOLDERDEPTH", 0)
    set_track_color(stem_track, color_entry and vary_color_entry(color_entry))

    local chains_ok, chain_err = apply_chain_files(stem_track, chain_files)
    if not chains_ok then
        return false, chain_err
    end

    if not add_fx_to_track(stem_track, extra_fx) then
        return false, "Could not add FX/chain to stem track: " .. stem.name
    end

    return true
end

local function chain_files_for_code(code)
    local chain_file = FX_CHAIN_BY_CODE[code]
    return chain_file and { chain_file } or {}
end

local function display_label(item)
    if item.display_name and item.display_name ~= item.name then
        return item.code .. "  " .. item.display_name
    end
    return item.code
end

local function close_current_folder(proj)
    local last_track = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
    if not last_track then
        return
    end

    local depth = reaper.GetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", depth - 1)
end

local function create_section(proj, section, extra_fx)
    local section_track = insert_track_at_end(proj, section.name)
    reaper.SetMediaTrackInfo_Value(section_track, "I_FOLDERDEPTH", 1)

    local section_color = current_color_map and current_color_map[section.code]
    set_track_color(section_track, section_color and section_color.color)

    local chains_ok, chain_err = apply_chain_files(section_track, chain_files_for_code(section.code))
    if not chains_ok then
        return false, chain_err
    end

    if not add_fx_to_track(section_track, extra_fx) then
        return false, "Could not add FX/chain to section folder track: " .. section.name
    end

    for _, stem in ipairs(section.stems or {}) do
        local ok, err = create_stem_track(
            proj,
            stem,
            chain_files_for_code(section.code),
            extra_fx,
            section_color
        )
        if not ok then
            return false, err
        end
    end

    close_current_folder(proj)
    return true
end

local function create_root_group(proj, group, extra_fx)
    local group_track = insert_track_at_end(proj, group.name)
    reaper.SetMediaTrackInfo_Value(group_track, "I_FOLDERDEPTH", 1)

    local group_color = current_color_map and current_color_map[group.code]
    set_track_color(group_track, group_color and group_color.color)

    local chains_ok, chain_err = apply_chain_files(group_track, chain_files_for_code(group.code))
    if not chains_ok then
        return false, chain_err
    end

    if not add_fx_to_track(group_track, extra_fx) then
        return false, "Could not add FX/chain to folder track: " .. group.name
    end

    for _, section in ipairs(group.sections or {}) do
        local ok, err = create_section(proj, section, extra_fx)
        if not ok then
            return false, err
        end
    end

    for _, stem in ipairs(group.stems or {}) do
        local ok, err = create_stem_track(
            proj,
            stem,
            chain_files_for_code(group.code),
            extra_fx,
            group_color
        )
        if not ok then
            return false, err
        end
    end

    close_current_folder(proj)
    return true
end

local function build_code_lookup()
    local lookup = {}
    for _, root in ipairs(ROOT_GROUPS) do
        lookup[root.code] = { kind = "root", value = root, root = root }

        for _, section in ipairs(root.sections or {}) do
            lookup[section.code] = {
                kind = "section",
                value = section,
                root = root,
            }

            for _, stem in ipairs(section.stems or {}) do
                lookup[stem.code] = {
                    kind = "stem",
                    value = stem,
                    root = root,
                    section = section,
                }
            end
        end

        for _, stem in ipairs(root.stems or {}) do
            lookup[stem.code] = {
                kind = "stem",
                value = stem,
                root = root,
            }
        end
    end
    return lookup
end

local function build_picker_rows()
    local rows = {}
    for _, root in ipairs(ROOT_GROUPS) do
        rows[#rows + 1] = {
            code = root.code,
            name = root.display_name or root.name,
            kind = "root",
            label = display_label(root),
        }

        for _, section in ipairs(root.sections or {}) do
            rows[#rows + 1] = {
                code = section.code,
                name = section.display_name or section.name,
                kind = "section",
                root_code = root.code,
                label = "  " .. display_label(section),
            }
            for _, stem in ipairs(section.stems or {}) do
                rows[#rows + 1] = {
                    code = stem.code,
                    name = stem.display_name or stem.name,
                    kind = "stem",
                    root_code = root.code,
                    section_code = section.code,
                    label = "    " .. display_label(stem),
                }
            end
        end

        for _, stem in ipairs(root.stems or {}) do
            rows[#rows + 1] = {
                code = stem.code,
                name = stem.display_name or stem.name,
                kind = "stem",
                root_code = root.code,
                label = "  " .. display_label(stem),
            }
        end
    end

    return rows
end

local function selected_codes_to_set(codes_text)
    local set = {}
    for _, code in ipairs(split_codes(codes_text)) do
        local normalized = CODE_ALIASES[code:lower()] or code:lower()
        set[normalized] = true
    end
    return set
end

local function selected_set_to_codes(selected)
    local codes = {}
    for _, row in ipairs(build_picker_rows()) do
        if selected[row.code] then
            codes[#codes + 1] = row.code
        end
    end
    return table.concat(codes, " ")
end

local function remove_child_codes_when_parent_selected(selected)
    for _, root in ipairs(ROOT_GROUPS) do
        if selected[root.code] then
            for _, section in ipairs(root.sections or {}) do
                selected[section.code] = false
                for _, stem in ipairs(section.stems or {}) do
                    selected[stem.code] = false
                end
            end
            for _, stem in ipairs(root.stems or {}) do
                selected[stem.code] = false
            end
        else
            for _, section in ipairs(root.sections or {}) do
                if selected[section.code] then
                    for _, stem in ipairs(section.stems or {}) do
                        selected[stem.code] = false
                    end
                end
            end
        end
    end
    return selected
end

local function copy_stem(stem)
    return {
        code = stem.code,
        name = stem.name,
        display_name = stem.display_name,
    }
end

local function copy_section(section)
    local section_copy = {
        code = section.code,
        name = section.name,
        display_name = section.display_name,
        stems = {},
    }
    for _, stem in ipairs(section.stems or {}) do
        section_copy.stems[#section_copy.stems + 1] = copy_stem(stem)
    end
    return section_copy
end

local function copy_root(root)
    local root_copy = {
        code = root.code,
        name = root.name,
        display_name = root.display_name,
        sections = {},
        stems = {},
    }
    for _, section in ipairs(root.sections or {}) do
        root_copy.sections[#root_copy.sections + 1] = copy_section(section)
    end
    for _, stem in ipairs(root.stems or {}) do
        root_copy.stems[#root_copy.stems + 1] = copy_stem(stem)
    end
    return root_copy
end

local function find_plan_root(plan, root)
    for _, entry in ipairs(plan) do
        if entry.code == root.code then
            return entry
        end
    end

    local root_copy = {
        code = root.code,
        name = root.name,
        display_name = root.display_name,
        sections = {},
        stems = {},
    }
    plan[#plan + 1] = root_copy
    return root_copy
end

local function find_plan_section(root_plan, section)
    for _, entry in ipairs(root_plan.sections or {}) do
        if entry.code == section.code then
            return entry
        end
    end

    local section_copy = {
        code = section.code,
        name = section.name,
        display_name = section.display_name,
        stems = {},
    }
    root_plan.sections[#root_plan.sections + 1] = section_copy
    return section_copy
end

local function add_unique_stem(stems, stem)
    for _, entry in ipairs(stems) do
        if entry.code == stem.code then
            return
        end
    end
    stems[#stems + 1] = copy_stem(stem)
end

local function add_requested_item_to_plan(plan, item)
    if item.kind == "root" then
        local root_plan = find_plan_root(plan, item.root)
        local root_copy = copy_root(item.root)
        root_plan.sections = root_copy.sections
        root_plan.stems = root_copy.stems
    elseif item.kind == "section" then
        local root_plan = find_plan_root(plan, item.root)
        local section_copy = copy_section(item.value)
        local section_plan = find_plan_section(root_plan, item.value)
        section_plan.stems = section_copy.stems
    elseif item.kind == "stem" then
        local root_plan = find_plan_root(plan, item.root)
        if item.section then
            local section_plan = find_plan_section(root_plan, item.section)
            add_unique_stem(section_plan.stems, item.value)
        else
            add_unique_stem(root_plan.stems, item.value)
        end
    end
end

local function collect_requested_groups(codes_text)
    local lookup = build_code_lookup()
    local plan = {}
    local unknown = {}
    local seen = {}

    codes_text = trim(codes_text)
    if codes_text == "" then
        return plan, unknown
    end
    if codes_text:lower() == "all" then
        codes_text = selected_set_to_codes(selected_codes_to_set("orch band"))
    else
        codes_text = selected_set_to_codes(remove_child_codes_when_parent_selected(selected_codes_to_set(codes_text)))
    end

    if codes_text == "" then
        return plan, unknown
    end

    for _, code in ipairs(split_codes(codes_text)) do
        local normalized = code:lower()
        normalized = CODE_ALIASES[normalized] or normalized
        local item = lookup[normalized]
        if item and not seen[normalized] then
            add_requested_item_to_plan(plan, item)
            seen[normalized] = true
        elseif not item then
            unknown[#unknown + 1] = code
        end
    end

    return plan, unknown
end

local function add_conflict_if_track_exists(proj, conflicts, name)
    if find_track_by_name(proj, name) then
        conflicts[#conflicts + 1] = name
    end
end

local function has_name_conflicts(proj, groups)
    local conflicts = {}

    add_conflict_if_track_exists(proj, conflicts, GLOBAL_FOLDER_NAME)

    for _, group in ipairs(groups) do
        add_conflict_if_track_exists(proj, conflicts, group.name)
        for _, section in ipairs(group.sections or {}) do
            add_conflict_if_track_exists(proj, conflicts, section.name)
            for _, stem in ipairs(section.stems or {}) do
                add_conflict_if_track_exists(proj, conflicts, stem.name)
            end
        end
        for _, stem in ipairs(group.stems or {}) do
            add_conflict_if_track_exists(proj, conflicts, stem.name)
        end
    end

    return conflicts
end

local function collect_required_chain_files(groups)
    local required = {}
    local seen = {}

    local function add_for_code(code)
        local chain_file = FX_CHAIN_BY_CODE[code]
        if chain_file and not seen[chain_file] then
            required[#required + 1] = chain_file
            seen[chain_file] = true
        end
    end

    for _, group in ipairs(groups) do
        add_for_code(group.code)
        for _, section in ipairs(group.sections or {}) do
            add_for_code(section.code)
        end
    end

    return required
end

local function validate_chain_files(groups)
    local missing = {}

    for _, chain_file in ipairs(collect_required_chain_files(groups)) do
        local path = get_chain_path(chain_file)
        if not file_exists(path) then
            missing[#missing + 1] = path
        end
    end

    if #missing > 0 then
        return false, missing
    end
    return true, missing
end

local function get_saved_settings()
    local extra_fx = reaper.GetExtState(EXT_SECTION, "extra_fx")
    local skip_conflicts = reaper.GetExtState(EXT_SECTION, "skip_conflicts")

    if extra_fx == "" then
        extra_fx = DEFAULT_EXTRA_FX
    end
    if skip_conflicts == "" then
        skip_conflicts = "Y"
    end

    return {
        extra_fx = extra_fx,
        skip_conflicts = bool_from_text(skip_conflicts),
    }
end

local function create_requested_structure(codes_text, settings)
    local proj = 0

    local groups, unknown = collect_requested_groups(codes_text)
    if #unknown > 0 then
        msg("Unknown code(s): " .. table.concat(unknown, ", "))
        return
    end
    if #groups == 0 then
        msg("No stem codes were requested.")
        return
    end

    local _, missing_chains = validate_chain_files(groups)

    if settings.skip_conflicts then
        local conflicts = has_name_conflicts(proj, groups)
        if #conflicts > 0 then
            msg(
                "These track names already exist, so nothing was created:\n\n"
                    .. table.concat(conflicts, "\n")
                    .. "\n\nTurn off 'Skip existing' in the picker if you want duplicates."
            )
            return
        end
    end

    reaper.Undo_BeginBlock()
    reaper.PreventUIRefresh(1)
    saved_selected_tracks = save_selected_tracks(proj)
    current_color_map = create_color_map()

    local ok, err = pcall(function()
        local global_folder_track = create_global_folder(proj)
        for _, group in ipairs(groups) do
            local created, create_err = create_root_group(proj, group, settings.extra_fx)
            if not created then
                error(create_err)
            end
        end
        close_folder_on_last_created_track(proj, global_folder_track)
    end)

    reaper.PreventUIRefresh(-1)
    restore_selected_tracks(proj, saved_selected_tracks)
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()

    if ok then
        reaper.Undo_EndBlock("GPHIL - create stem track structure", -1)
        if #missing_chains > 0 then
            msg(
                "Track structure was created, but these FX chain file(s) were missing and skipped:\n\n"
                    .. table.concat(missing_chains, "\n")
            )
        end
    else
        reaper.Undo_EndBlock("GPHIL - create stem track structure failed", -1)
        msg(tostring(err))
    end
end

local function draw_button(x, y, w, h, label)
    local mx = gfx.mouse_x
    local my = gfx.mouse_y
    local hover = mx >= x and mx <= x + w and my >= y and my <= y + h

    if hover then
        gfx.set(0.32, 0.32, 0.38, 1)
    else
        gfx.set(0.22, 0.22, 0.28, 1)
    end
    gfx.rect(x, y, w, h, 1)
    gfx.set(1, 1, 1, 1)
    gfx.x = x + 10
    gfx.y = y + 8
    gfx.drawstr(label)
    return hover
end

local function draw_checkbox(x, y, checked, dimmed)
    gfx.set(0.08, 0.08, 0.095, 1)
    gfx.rect(x, y, 16, 16, 1)
    gfx.set(0.55, 0.55, 0.6, 1)
    gfx.rect(x, y, 16, 16, 0)
    if checked then
        if dimmed then
            gfx.set(0.35, 0.45, 0.55, 1)
        else
            gfx.set(0.35, 0.68, 0.95, 1)
        end
        gfx.rect(x + 4, y + 4, 8, 8, 1)
    end
end

local function show_stem_picker()
    local rows = build_picker_rows()
    local saved_codes = reaper.GetExtState(EXT_SECTION, "codes")
    local selected
    if trim(saved_codes):lower() == "all" then
        selected = selected_codes_to_set("orch band")
    else
        selected = selected_codes_to_set(saved_codes)
    end
    local settings = get_saved_settings()
    local last_left_down = false
    local message = "Select stem buses to create."

    gfx.init(SCRIPT_TITLE, 520, 760)
    gfx.setfont(1, "Arial", 16)

    local function any_selected()
        for _, row in ipairs(rows) do
            if selected[row.code] then
                return true
            end
        end
        return false
    end

    local function set_all(value)
        for _, row in ipairs(rows) do
            selected[row.code] = value
        end
    end

    local function selected_codes()
        return selected_set_to_codes(remove_child_codes_when_parent_selected(selected))
    end

    local function loop()
        gfx.set(0.1, 0.1, 0.12, 1)
        gfx.rect(0, 0, gfx.w, gfx.h, 1)

        gfx.set(1, 1, 1, 1)
        gfx.x = 16
        gfx.y = 16
        gfx.drawstr("Stem Track Structure")

        local create_hover = draw_button(16, 52, 96, 34, "Create")
        local all_hover = draw_button(124, 52, 72, 34, "All")
        local none_hover = draw_button(208, 52, 72, 34, "None")
        local cancel_hover = draw_button(292, 52, 88, 34, "Cancel")

        local skip_x = 398
        local skip_y = 61
        local skip_hover = gfx.mouse_x >= skip_x and gfx.mouse_x <= skip_x + 112 and gfx.mouse_y >= skip_y - 6 and gfx.mouse_y <= skip_y + 24
        if skip_hover then
            gfx.set(0.16, 0.17, 0.21, 1)
            gfx.rect(skip_x - 8, skip_y - 6, 112, 28, 1)
        end
        draw_checkbox(skip_x, skip_y, settings.skip_conflicts, false)
        gfx.set(0.9, 0.9, 0.94, 1)
        gfx.x = skip_x + 24
        gfx.y = skip_y
        gfx.drawstr("Skip existing")

        gfx.set(0.75, 0.75, 0.78, 1)
        gfx.x = 16
        gfx.y = 104
        gfx.drawstr("Section rows create global buses. Child rows create individual stem buses.")

        local y = 134
        local row_h = 24
        for i, row in ipairs(rows) do
            local parent_selected = selected[row.root_code] or (row.section_code and selected[row.section_code])
            local row_y = y + (i - 1) * row_h
            local hover = gfx.mouse_x >= 16 and gfx.mouse_x <= gfx.w - 16 and gfx.mouse_y >= row_y and gfx.mouse_y <= row_y + row_h

            if hover then
                gfx.set(0.16, 0.17, 0.21, 1)
                gfx.rect(16, row_y, gfx.w - 32, row_h, 1)
            elseif row.kind == "root" or row.kind == "section" then
                gfx.set(0.13, 0.14, 0.17, 1)
                gfx.rect(16, row_y, gfx.w - 32, row_h, 1)
            end

            draw_checkbox(24, row_y + 4, selected[row.code] or parent_selected, parent_selected)
            if parent_selected then
                gfx.set(0.55, 0.57, 0.62, 1)
            elseif row.kind == "root" or row.kind == "section" then
                gfx.set(0.95, 0.95, 0.98, 1)
            else
                gfx.set(0.82, 0.84, 0.88, 1)
            end
            gfx.x = 50
            gfx.y = row_y + 4
            gfx.drawstr(row.label)
        end

        local footer_y = gfx.h - 42
        gfx.set(0.16, 0.16, 0.2, 1)
        gfx.rect(0, footer_y, gfx.w, 42, 1)
        gfx.set(1, 1, 1, 1)
        gfx.x = 16
        gfx.y = footer_y + 12
        gfx.drawstr(message)

        gfx.update()
        local char = gfx.getchar()
        if char < 0 or char == 27 then
            gfx.quit()
            return
        end

        local left_down = (gfx.mouse_cap % 2) == 1
        if left_down and not last_left_down then
            local mx = gfx.mouse_x
            local my = gfx.mouse_y

            if create_hover then
                if not any_selected() then
                    message = "Select at least one stem."
                else
                    local codes = selected_codes()
                    reaper.SetExtState(EXT_SECTION, "codes", codes, true)
                    gfx.quit()
                    create_requested_structure(codes, settings)
                    return
                end
            elseif all_hover then
                set_all(true)
                message = "All rows selected."
            elseif none_hover then
                set_all(false)
                message = "Selection cleared."
            elseif cancel_hover then
                gfx.quit()
                return
            elseif skip_hover then
                settings.skip_conflicts = not settings.skip_conflicts
                reaper.SetExtState(EXT_SECTION, "skip_conflicts", settings.skip_conflicts and "Y" or "N", true)
                message = settings.skip_conflicts and "Existing track names will be skipped." or "Duplicate track names are allowed."
            else
                for i, row in ipairs(rows) do
                    local row_y = y + (i - 1) * row_h
                    if mx >= 16 and mx <= gfx.w - 16 and my >= row_y and my <= row_y + row_h then
                        selected[row.code] = not selected[row.code]
                        message = row.name .. (selected[row.code] and " selected." or " cleared.")
                        break
                    end
                end
            end
        end
        last_left_down = left_down

        reaper.defer(loop)
    end

    loop()
end

local function main()
    show_stem_picker()
end

main()
