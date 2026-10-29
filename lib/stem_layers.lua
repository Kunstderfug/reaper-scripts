-- Discover render buses and manage their selection independently of the mixer UI.
local M = {}

local LABELS = {
    stems = 'Combined stems', orch = 'Orchestra', w = 'Woodwinds', b = 'Brass',
    p = 'Percussion', s = 'Strings', band = 'Band',
    fl = 'Flutes', ob = 'Oboes', cl = 'Clarinets', bsn = 'Bassoons',
    hn = 'Horns', tr = 'Trumpets', tn = 'Trombones', tb = 'Tuba',
    ti = 'Timpani', sd = 'Snare Drum', sn = 'Snare Drum', bd = 'Bass Drum',
    cy = 'Cymbals', pi = 'Piano', vln1 = 'Violin 1', vln2 = 'Violin 2',
    vla = 'Viola', vc = 'Cello', db = 'Double Basses',
    sx = 'Saxophones', lg = 'Lead Guitar', bg = 'Bass Guitar',
    dr = 'Drums', ab = 'Acoustic Bass',
    w_stem = 'Woodwinds', b_stem = 'Brass', p_stem = 'Percussion',
    s_stem = 'Strings',
}

local function normalized(name)
    return (name or ''):match('^%s*(.-)%s*$'):lower()
end

local function row_for(r, track, depth, parent_guid, root)
    local _, name = r.GetTrackName(track)
    name = name or ''
    return {
        track = track,
        guid = r.GetTrackGUID(track),
        name = name,
        label = LABELS[normalized(name)] or name,
        selectable = not root and normalized(name) ~= 'orch',
        depth = depth,
        parent_guid = parent_guid,
        kind = root and 'root'
            or (r.GetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH') > 0 and 'group' or 'stem'),
    }
end

function M.discover(r, project)
    local rows, legacy, folders = {}, {}, {}
    local root_depth
    for i = 0, r.CountTracks(project) - 1 do
        local track = r.GetTrack(project, i)
        local _, name = r.GetTrackName(track)
        local code = normalized(name)
        local delta = r.GetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH')
        local starts_tree = root_depth == nil and code == 'stems' and delta > 0
        if starts_tree then root_depth = #folders end
        if root_depth ~= nil then
            local parent = #folders > root_depth and folders[#folders] or nil
            rows[#rows + 1] = row_for(r, track, #folders - root_depth,
                parent and parent.guid, starts_tree)
        elseif code:match('^.+_stem$') then
            legacy[#legacy + 1] = row_for(r, track, 0, nil, false)
        end

        if delta > 0 then
            local folder = { guid = r.GetTrackGUID(track) }
            for _ = 1, delta do folders[#folders + 1] = folder end
        elseif delta < 0 then
            for _ = 1, -delta do folders[#folders] = nil end
        end
        if root_depth ~= nil and #folders <= root_depth then root_depth = nil end
    end
    return #rows > 0 and rows or legacy
end

-- Keep routing wrappers in discovery for mute restoration, but omit them from
-- render choices and flatten their indentation in the picker.
function M.picker_rows(rows)
    local choices, by_guid = {}, {}
    for _, row in ipairs(rows) do by_guid[row.guid] = row end
    for _, row in ipairs(rows) do
        if row.selectable ~= false then
            local depth, ancestor = 0, by_guid[row.parent_guid]
            while ancestor do
                if ancestor.selectable ~= false then depth = depth + 1 end
                ancestor = by_guid[ancestor.parent_guid]
            end
            row.display_depth = depth
            choices[#choices + 1] = row
        end
    end
    return choices
end

function M.selected(rows, r)
    local selected = {}
    for _, row in ipairs(rows) do
        if row.selectable ~= false and r.IsTrackSelected(row.track) then selected[row.guid] = true end
    end
    return selected
end

function M.tracks(rows, selected)
    local tracks = {}
    for _, row in ipairs(rows) do
        if row.selectable ~= false and selected[row.guid] then tracks[#tracks + 1] = row.track end
    end
    return tracks
end

-- Every row is one render output, including section buses.
function M.toggle(rows, selected, row_index)
    local row = rows[row_index]
    selected[row.guid] = not selected[row.guid]
end

local function valid(r, project, entry)
    return entry.track and r.ValidatePtr2(project, entry.track, 'MediaTrack*')
        and r.GetTrackGUID(entry.track) == entry.guid
end

local function set_selection(r, project, wanted)
    for i = 0, r.CountTracks(project) - 1 do
        local track = r.GetTrack(project, i)
        r.SetTrackSelected(track, wanted[track] == true)
    end
end

function M.validate(r, project, rows, selected)
    local by_guid, count = {}, 0
    for _, row in ipairs(rows) do by_guid[row.guid] = row end
    for guid, enabled in pairs(selected) do
        if enabled then
            local row = by_guid[guid]
            if not row or row.selectable == false or not valid(r, project, row) then
                return false, 'A selected stem track changed or was removed. Reopen the stem picker.'
            end
            count = count + 1
        end
    end
    if count == 0 then return false, 'Select at least one stem layer.' end
    return true
end

function M.apply(r, project, rows, selected)
    local ok, err = M.validate(r, project, rows, selected)
    if not ok then return false, err end
    local wanted = {}
    for _, track in ipairs(M.tracks(rows, selected)) do wanted[track] = true end
    set_selection(r, project, wanted)
    return true
end

function M.capture_selection(r, project)
    local snapshot = {}
    for i = 0, r.CountTracks(project) - 1 do
        local track = r.GetTrack(project, i)
        if r.IsTrackSelected(track) then
            snapshot[#snapshot + 1] = { track = track, guid = r.GetTrackGUID(track) }
        end
    end
    return snapshot
end

function M.restore_selection(r, project, snapshot)
    local wanted = {}
    for _, entry in ipairs(snapshot) do
        if valid(r, project, entry) then wanted[entry.track] = true end
    end
    set_selection(r, project, wanted)
end

return M
