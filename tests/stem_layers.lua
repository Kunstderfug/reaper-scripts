local model = dofile('lib/stem_layers.lua')

local function fixture(spec)
    local project, other_project = {}, {}
    local tracks, writes = {}, 0
    for i, item in ipairs(spec) do
        tracks[i] = { name = item[1], delta = item[2] or 0,
            selected = item[3] or false, guid = '{' .. i .. '}', project = project }
    end
    local r = {
        CountTracks = function(p) assert(p == project); return #tracks end,
        GetTrack = function(p, i) assert(p == project); return tracks[i + 1] end,
        GetTrackName = function(t) return true, t.name end,
        GetTrackGUID = function(t) return t.guid end,
        GetMediaTrackInfo_Value = function(t, key)
            assert(key == 'I_FOLDERDEPTH'); return t.delta
        end,
        IsTrackSelected = function(t) return t.selected end,
        SetTrackSelected = function(t, value) t.selected = value; writes = writes + 1 end,
        ValidatePtr2 = function(p, t, kind)
            assert(kind == 'MediaTrack*')
            return not t.deleted and t.project == p
        end,
    }
    return r, project, tracks, function() return writes end, other_project
end

-- Real projects have duplicate abbreviation tracks outside the STEMS tree and
-- may nest that tree inside another folder. Multi-level closing tracks belong
-- to the tree; the following track does not.
local r, project, tracks = fixture({
    { 'w', 1 }, { 'WW', -1 }, { 'W_STEM' }, { 'Mix', 1 },
    { ' STEMS ', 1 }, { 'orch', 1 }, { 'w', 1 },
    { 'fl', 0, true }, { 'ob', -1 }, { 's', 1 },
    { 'vln1', -3 }, { 'Outside', -1 }, { 'B_STEM' },
    { 'STEMS', 1 }, { 'band', 1 }, { 'sx', -2 }, { 'After' },
})
local rows = model.discover(r, project)
assert(#rows == 10 and rows[1].track == tracks[5] and rows[7].track == tracks[11])
assert(rows[1].kind == 'root' and rows[1].depth == 0 and not rows[1].parent_guid)
assert(rows[1].label == 'Combined stems')
assert(rows[2].kind == 'group' and rows[2].depth == 1
    and rows[2].parent_guid == rows[1].guid)
assert(rows[4].label == 'Flutes' and rows[4].name == 'fl' and rows[4].depth == 3)
assert(rows[4].parent_guid == rows[3].guid and rows[5].parent_guid == rows[3].guid)
assert(rows[6].parent_guid == rows[2].guid and rows[7].parent_guid == rows[6].guid)
assert(rows[8].kind == 'root' and rows[8].depth == 0 and rows[10].label == 'Saxophones')
local choices = model.picker_rows(rows)
assert(#choices == 7 and choices[1].label == 'Woodwinds' and choices[4].label == 'Strings')
assert(choices[1].display_depth == 0 and choices[2].display_depth == 1)
assert(choices[6].label == 'Band' and choices[6].display_depth == 0
    and choices[7].label == 'Saxophones' and choices[7].display_depth == 1)
local visible_selection = {}
model.toggle(choices, visible_selection, 1)
assert(#model.tracks(rows, visible_selection) == 1 and model.validate(r, project, rows, visible_selection))
assert(not visible_selection[rows[1].guid] and not visible_selection[rows[2].guid])
assert(not visible_selection[rows[6].guid] and not visible_selection[rows[9].guid])
model.toggle(choices, visible_selection, 6)
assert(visible_selection[rows[9].guid] and not visible_selection[rows[10].guid])
assert(not model.validate(r, project, rows, { [rows[1].guid] = true }))
assert(not model.validate(r, project, rows, { [rows[2].guid] = true }))
assert(#model.tracks(rows, { [rows[1].guid] = true, [rows[2].guid] = true }) == 0)
local selected = model.selected(rows, r)
assert(selected[tracks[8].guid] and not selected[tracks[7].guid])

-- Section and instrument choices remain independent in both directions.
local independent = {}
model.toggle(choices, independent, 1) -- Woodwinds only.
assert(independent[rows[3].guid] and not independent[rows[4].guid]
    and not independent[rows[5].guid])
model.toggle(choices, independent, 2) -- Add Flutes explicitly.
assert(independent[rows[3].guid] and independent[rows[4].guid])
model.toggle(choices, independent, 1) -- Section off preserves Flutes.
assert(not independent[rows[3].guid] and independent[rows[4].guid])
model.toggle(choices, independent, 2)
assert(#model.tracks(rows, independent) == 0)

-- A parent and its child are distinct outputs, with exact ordered track identity.
local snapshot = model.capture_selection(r, project)
selected = { [rows[3].guid] = true, [rows[4].guid] = true }
local chosen = model.tracks(rows, selected)
assert(#chosen == 2 and chosen[1] == tracks[7] and chosen[2] == tracks[8])
assert(model.apply(r, project, rows, selected))
for _, track in ipairs(tracks) do
    assert(track.selected == (track == tracks[7] or track == tracks[8]))
end
model.restore_selection(r, project, snapshot)
for _, track in ipairs(tracks) do assert(track.selected == (track == tracks[8])) end

-- Legacy fallback is anchored, case-insensitive, and never grabs plain w/b/s.
r, project, tracks = fixture({
    { 'STEMS' }, { 'w' }, { ' W_STEM ' }, { 'my_stem' }, { 'B_STEM extra' }, { 's' },
})
rows = model.discover(r, project)
assert(#rows == 2 and rows[1].track == tracks[3] and rows[2].track == tracks[4])
assert(rows[1].label == 'Woodwinds' and rows[2].label == 'my_stem')
assert(not rows[1].parent_guid and rows[1].depth == 0)

-- Every invalid choice must fail before touching even the previous selection.
local write_count, other
r, project, tracks, write_count, other = fixture({
    { 'STEMS', 1 }, { 'w', 1 }, { 'fl', -2 }, { 'Original', 0, true },
})
rows = model.discover(r, project)
local function unchanged(selection)
    local before = write_count()
    local valid, validation_error = model.validate(r, project, rows, selection)
    assert(not valid and type(validation_error) == 'string' and write_count() == before)
    local ok, err = model.apply(r, project, rows, selection)
    assert(not ok and err == validation_error and write_count() == before)
    assert(tracks[4].selected and not tracks[2].selected)
end
assert(model.validate(r, project, rows, { [rows[2].guid] = true }))
assert(write_count() == 0 and tracks[4].selected and not tracks[2].selected,
    'Successful validation changed the selection')
unchanged({})
unchanged({ ['{unknown}'] = true, [rows[2].guid] = true })
tracks[3].deleted = true
unchanged({ [rows[2].guid] = true, [rows[3].guid] = true })
tracks[3].deleted, tracks[3].project = nil, other
unchanged({ [rows[3].guid] = true })
tracks[3].project, tracks[3].guid = project, '{reused-pointer}'
unchanged({ [rows[3].guid] = true })

-- Restoration tolerates deletion without selecting a reused pointer or another project.
tracks[2].selected, tracks[3].selected = true, true
snapshot = model.capture_selection(r, project)
tracks[2].deleted, tracks[3].guid = true, '{changed-again}'
tracks[4].selected = false
model.restore_selection(r, project, snapshot)
assert(not tracks[2].selected and not tracks[3].selected and tracks[4].selected)

print('PASS: stem hierarchy, duplicate names, legacy fallback, independent outputs, validation and restoration')
