-- Select render buses using clear orchestral layer labels.
-- Selection only: use the normal Render dialog or the existing stem renderer next.
local directory = debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])')
local model = dofile(directory .. 'lib/stem_layers.lua')
local picker = dofile(directory .. 'lib/stem_layer_picker.lua')
local project = reaper.EnumProjects(-1, '')
picker.show(reaper, gfx, model, project, { confirm_label = 'Select tracks' }, function(selected, rows)
    if not selected then return end
    local ok, err = model.apply(reaper, project, rows, selected)
    if not ok then reaper.ShowMessageBox(err, 'Stem render layers', 0) end
    reaper.UpdateArrange()
end)
