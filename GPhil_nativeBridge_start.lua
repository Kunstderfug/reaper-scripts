-- Local native API bridge. Idempotent; also started by Scripts/__startup.lua.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
dofile(root .. 'lib/native_bridge.lua').start(reaper, root)
