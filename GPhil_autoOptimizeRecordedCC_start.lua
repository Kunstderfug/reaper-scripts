-- Background monitor. Use the separate toggle action to turn it on or off.
-- Started by REAPER __startup.lua; persisted Off remains Off across launches.
local root=assert(debug.getinfo(1,'S').source:sub(2):match('^(.*[/\\])'))
dofile(root..'lib/cc_recording_service.lua').start(reaper,root)
