-- GFX front end for the scoped, single-Undo CC gesture optimizer.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local ok, err = xpcall(function()
    dofile(root .. 'lib/cc_window.lua').open(reaper, gfx, root)
end, debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err), 'CC gestures', 0) end
