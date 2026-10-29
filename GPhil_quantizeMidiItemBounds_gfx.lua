-- Pad MIDI items to enclosing barlines without quantizing any MIDI events.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
dofile(root .. 'lib/midi_item_bounds_window.lua').open(reaper, gfx)
