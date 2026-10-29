-- Toggle: align recorded MIDI bounds, optimize CCs, then open all recorded items.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
dofile(root .. 'lib/midi_record_toggle.lua').start(reaper, root, 'full')
