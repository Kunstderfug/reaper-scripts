-- Optimize CC gestures in selected MIDI items, selected tracks, or the project.
-- Applies directly with one Undo step. Whole-project scope backs up then saves.
-- Auto detects eligible CC lanes used within the chosen scope.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local ok, err = xpcall(function()
    return dofile(root .. 'lib/cc_optimizer.lua').run(reaper, root)
end, debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err), 'CC curve optimization', 0) end
