-- Toggle silent CC1/3/11/13/21/22 optimization after MIDI recording stops.
-- Toolbar state reflects enabled monitoring. One Undo per completed pass; no save.
local root=assert(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])'))
dofile(root..'lib/cc_recording_service.lua').toggle(reaper,root)
