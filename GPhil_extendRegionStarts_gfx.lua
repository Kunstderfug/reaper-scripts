-- Extend opening audio items/regions, with snap anchors at the new left edge.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
dofile(root .. 'lib/region_start_window.lua').open(reaper, gfx)
