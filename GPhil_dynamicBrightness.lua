-- GPhil GFX controller for a separate, native audio-driven ReaEQ high shelf.
-- Save the project to retain the EQ. Last-used settings and presets are global.
local directory = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local ok, err = xpcall(function()
    dofile(directory .. 'lib/dynamic_brightness_window.lua').open(reaper, gfx)
end, debug.traceback)
if not ok then reaper.ShowMessageBox(tostring(err), 'Dynamic brightness', 0) end
