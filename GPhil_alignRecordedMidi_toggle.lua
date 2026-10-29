-- Toggle: align recorded MIDI bounds and open all recorded items; leave CCs intact.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
dofile(root .. 'lib/midi_record_toggle.lua').start(reaper, root, 'align')
