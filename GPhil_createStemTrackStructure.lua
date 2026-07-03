-- GPhil_createStemTrackStructure.lua
-- Create a standard orchestral stem folder/child track structure.
--
-- Each stem is a render bus folder track with a same-named source child track
-- inside it. Section tracks are render buses too. Source child tracks feed the
-- individual stem bus through normal folder routing and also send to their
-- section bus in parallel, while stem bus parent sends are disabled to avoid
-- double-processing in section renders.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper
---@diagnostic disable-next-line: undefined-global
local gfx = gfx

local EXT_SECTION = "GPhilCreateStemTrackStructure"
local SCRIPT_TITLE = "Create Stem Track Structure"
local GLOBAL_FOLDER_NAME = "STEMS"

local FX_CHAIN_SUBDIR = "GPHIL"
local MASTER_CHAIN = "GPHIL_STEM_MASTER.RfxChain"

local SECTION_CHAIN_BY_CODE = {
    w = "GPHIL_STEM_W.RfxChain",
    b = "GPHIL_STEM_B.RfxChain",
    p = "GPHIL_STEM_P.RfxChain",
    s = "GPHIL_STEM_S.RfxChain",
}

-- Optional extra FX/plugin/action to apply after the automatic GPhil chains.
local DEFAULT_EXTRA_FX = ""
local saved_selected_tracks = nil
local current_color_map = nil

local SECTION_STRUCTURE = {
    {
        code = "w",
        name = "Woodwinds",
        stems = {
            { code = "fl", name = "Flutes" },
            { code = "ob", name = "Oboes" },
            { code = "cl", name = "Clarinets" },
            { code = "bsn", name = "Bassoons" },
        },
    },
    {
        code = "b",
        name = "Brass",
        stems = {
            { code = "hn", name = "Horns" },
            { code = "tr", name = "Trumpets" },
            { code = "tn", name = "Trombones" },
            { code = "tb", name = "Tuba" },
        },
    },
    {
        code = "p",
        name = "Percussion",
        stems = {
            { code = "ti", name = "Timpani" },
            { code = "sd", name = "Snare Drum" },
            { code = "bd", name = "Bass Drum" },
            { code = "cy", name = "Cymbals" },
            { code = "pi", name = "Piano" },
        },
    },
    {
        code = "s",
        name = "Strings",
        stems = {
            { code = "vln1", name = "Violin1" },
            { code = "vln2", name = "Violin2" },
            { code = "vla", name = "Viola" },
            { code = "vc", name = "Cello" },
            { code = "db", name = "DoubleBasses" },
        },
    },
}

local STANDALONE_STEMS = {
    { code = "orch", name = "Orchestra" },
    { code = "f", name = "Full Score" },
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
        standalone = random_color_entry(),
    }

    for _, section in ipairs(SECTION_STRUCTURE) do
        map[section.code] = random_color_entry()
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
    return table.concat({ reaper.GetResourcePath(), "FXChains", FX_CHAIN_SUBDIR, chain_file }, "/")
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
        local ok, err = append_fx_chain_to_track(track, chain_file)
        if not ok then
            return false, err
        end
    end
    return true
end

local function create_post_fader_send(source_track, destination_track)
    local send_index = reaper.CreateTrackSend(source_track, destination_track)
    if not send_index or send_index < 0 then
        return false
    end

    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "I_SENDMODE", 0) -- post-fader/post-pan
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_VOL", 1.0)
    reaper.SetTrackSendInfo_Value(source_track, 0, send_index, "D_PAN", 0.0)
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

local function create_folder_pair(proj, stem, chain_files, extra_fx, section_track, color_entry)
    local folder_track = insert_track_at_end(proj, stem.name)
    local child_track = insert_track_at_end(proj, stem.name)

    reaper.SetMediaTrackInfo_Value(folder_track, "I_FOLDERDEPTH", 1)
    reaper.SetMediaTrackInfo_Value(child_track, "I_FOLDERDEPTH", -1)
    set_track_color(folder_track, color_entry and color_entry.color)
    set_track_color(child_track, color_entry and vary_color_entry(color_entry))

    if section_track then
        -- Keep visual nesting without feeding the section bus with processed stem audio.
        reaper.SetMediaTrackInfo_Value(folder_track, "B_MAINSEND", 0)
        if not create_post_fader_send(child_track, section_track) then
            return false, "Could not create parallel send from " .. stem.name .. " source to section bus."
        end
    end

    local chains_ok, chain_err = apply_chain_files(folder_track, chain_files)
    if not chains_ok then
        return false, chain_err
    end

    if not add_fx_to_track(folder_track, extra_fx) then
        return false, "Could not add FX/chain to folder track: " .. stem.name
    end

    return true
end

local function create_section(proj, section, extra_fx)
    local section_track = insert_track_at_end(proj, section.name)
    reaper.SetMediaTrackInfo_Value(section_track, "I_FOLDERDEPTH", 1)

    local section_chain = SECTION_CHAIN_BY_CODE[section.code]
    local section_chains = section_chain and { section_chain, MASTER_CHAIN } or { MASTER_CHAIN }
    local section_color = current_color_map and current_color_map[section.code]
    set_track_color(section_track, section_color and section_color.color)

    local chains_ok, chain_err = apply_chain_files(section_track, section_chains)
    if not chains_ok then
        return false, chain_err
    end

    if not add_fx_to_track(section_track, extra_fx) then
        return false, "Could not add FX/chain to section folder track: " .. section.name
    end

    local stem_chains = section_chain and { section_chain, MASTER_CHAIN } or { MASTER_CHAIN }
    for _, stem in ipairs(section.stems) do
        local ok, err = create_folder_pair(proj, stem, stem_chains, extra_fx, section_track, section_color)
        if not ok then
            return false, err
        end
    end

    local last_track = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
    local depth = reaper.GetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH")
    reaper.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", depth - 1)
    return true
end

local function build_code_lookup()
    local lookup = {}
    for _, section in ipairs(SECTION_STRUCTURE) do
        lookup[section.code] = { kind = "section", value = section }
        for _, stem in ipairs(section.stems) do
            local section_chain = SECTION_CHAIN_BY_CODE[section.code]
            local chain_files = section_chain and { section_chain, MASTER_CHAIN } or { MASTER_CHAIN }
            lookup[stem.code] = {
                kind = "stem",
                value = stem,
                chain_files = chain_files,
                color_key = section.code,
            }
        end
    end
    for _, stem in ipairs(STANDALONE_STEMS) do
        lookup[stem.code] = {
            kind = "stem",
            value = stem,
            chain_files = { MASTER_CHAIN },
            color_key = "standalone",
        }
    end
    return lookup
end

local function build_picker_rows()
    local rows = {}
    for _, section in ipairs(SECTION_STRUCTURE) do
        rows[#rows + 1] = {
            code = section.code,
            name = section.name,
            kind = "section",
            label = section.code .. "  " .. section.name,
        }
        for _, stem in ipairs(section.stems) do
            rows[#rows + 1] = {
                code = stem.code,
                name = stem.name,
                kind = "stem",
                section_code = section.code,
                label = "  " .. stem.code .. "  " .. stem.name,
            }
        end
    end

    for _, stem in ipairs(STANDALONE_STEMS) do
        rows[#rows + 1] = {
            code = stem.code,
            name = stem.name,
            kind = "stem",
            label = stem.code .. "  " .. stem.name,
        }
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

local function remove_child_codes_when_section_selected(selected)
    for _, section in ipairs(SECTION_STRUCTURE) do
        if selected[section.code] then
            for _, stem in ipairs(section.stems) do
                selected[stem.code] = false
            end
        end
    end
    return selected
end

local function collect_requested_items(codes_text)
    local lookup = build_code_lookup()
    local requested = {}
    local unknown = {}
    local seen = {}

    codes_text = trim(codes_text)
    if codes_text == "" then
        return requested, unknown
    end
    if codes_text:lower() == "all" then
        codes_text = selected_set_to_codes(selected_codes_to_set("w b p s orch f"))
    else
        codes_text = selected_set_to_codes(remove_child_codes_when_section_selected(selected_codes_to_set(codes_text)))
    end

    if codes_text == "" then
        return requested, unknown
    end

    for _, code in ipairs(split_codes(codes_text)) do
        local normalized = code:lower()
        normalized = CODE_ALIASES[normalized] or normalized
        local item = lookup[normalized]
        if item and not seen[normalized] then
            requested[#requested + 1] = item
            seen[normalized] = true
        elseif not item then
            unknown[#unknown + 1] = code
        end
    end

    return requested, unknown
end

local function has_name_conflicts(proj, items)
    local conflicts = {}

    if find_track_by_name(proj, GLOBAL_FOLDER_NAME) then
        conflicts[#conflicts + 1] = GLOBAL_FOLDER_NAME
    end

    for _, item in ipairs(items) do
        if item.kind == "section" then
            if find_track_by_name(proj, item.value.name) then
                conflicts[#conflicts + 1] = item.value.name
            end
            for _, stem in ipairs(item.value.stems) do
                if find_track_by_name(proj, stem.name) then
                    conflicts[#conflicts + 1] = stem.name
                end
            end
        elseif find_track_by_name(proj, item.value.name) then
            conflicts[#conflicts + 1] = item.value.name
        end
    end

    return conflicts
end

local function validate_chain_files()
    local missing = {}

    for _, chain_file in pairs(SECTION_CHAIN_BY_CODE) do
        local path = get_chain_path(chain_file)
        if not file_exists(path) then
            missing[#missing + 1] = path
        end
    end

    local master_path = get_chain_path(MASTER_CHAIN)
    if not file_exists(master_path) then
        missing[#missing + 1] = master_path
    end

    if #missing > 0 then
        return false, missing
    end
    return true
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

    local items, unknown = collect_requested_items(codes_text)
    if #unknown > 0 then
        msg("Unknown code(s): " .. table.concat(unknown, ", "))
        return
    end
    if #items == 0 then
        msg("No stem codes were requested.")
        return
    end

    local chains_ok, missing_chains = validate_chain_files()
    if not chains_ok then
        msg("Required FX chain file(s) are missing:\n\n" .. table.concat(missing_chains, "\n"))
        return
    end

    if settings.skip_conflicts then
        local conflicts = has_name_conflicts(proj, items)
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
        for _, item in ipairs(items) do
            if item.kind == "section" then
                local created, create_err = create_section(proj, item.value, settings.extra_fx)
                if not created then
                    error(create_err)
                end
            else
                local color_entry = current_color_map and current_color_map[item.color_key]
                local created, create_err = create_folder_pair(
                    proj,
                    item.value,
                    item.chain_files,
                    settings.extra_fx,
                    nil,
                    color_entry
                )
                if not created then
                    error(create_err)
                end
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
        selected = selected_codes_to_set("w b p s orch f")
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
        return selected_set_to_codes(remove_child_codes_when_section_selected(selected))
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
            local parent_selected = row.section_code and selected[row.section_code]
            local row_y = y + (i - 1) * row_h
            local hover = gfx.mouse_x >= 16 and gfx.mouse_x <= gfx.w - 16 and gfx.mouse_y >= row_y and gfx.mouse_y <= row_y + row_h

            if hover then
                gfx.set(0.16, 0.17, 0.21, 1)
                gfx.rect(16, row_y, gfx.w - 32, row_h, 1)
            elseif row.kind == "section" then
                gfx.set(0.13, 0.14, 0.17, 1)
                gfx.rect(16, row_y, gfx.w - 32, row_h, 1)
            end

            draw_checkbox(24, row_y + 4, selected[row.code] or parent_selected, parent_selected)
            if parent_selected then
                gfx.set(0.55, 0.57, 0.62, 1)
            elseif row.kind == "section" then
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
