-- Run with a fresh temporary directory argument (created by the caller).
local base = assert(arg[1], 'Expected a fresh temporary directory')
local protocol = dofile('lib/native_bridge_protocol.lua')
local bridge = dofile('lib/native_bridge.lua')
local root = base .. '/GPhilBridge'
local state, next_loop, on_exit, clock, cached = {}, nil, nil, 0, nil
local known, refreshes = {}, 0
local api = {
    GetResourcePath=function() return base end,
    GetExtState=function(_, key) return state[key] or '' end,
    SetExtState=function(_, key, value) state[key] = value end,
    DeleteExtState=function(_, key) state[key] = nil end,
    RecursiveCreateDirectory=function() end, -- directories precreated by caller
    genGuid=function() return '1234567890abcdef1234567890abcdef' end,
    GetAppVersion=function() return 'test' end,
    time_precise=function() return clock end,
    atexit=function(callback) on_exit = callback end,
    defer=function(callback) next_loop = callback end,
    ShowConsoleMsg=function(message) error(message) end,
    EnumerateFiles=function(_, i)
        if i == -1 then cached = nil; refreshes = refreshes + 1; return end
        if not cached then
            cached = {}
            for _, name in ipairs(known) do
                local f = io.open(root .. '/inbox/' .. name, 'rb')
                if f then f:close(); cached[#cached + 1] = name end
            end
        end
        return cached[i + 1]
    end,
}
local function enqueue(id, fields)
    local name = id .. '.request'
    known[#known + 1] = name
    protocol.write(root .. '/inbox/' .. name, fields)
end
local function tick() clock = clock + 0.3; local run = next_loop; next_loop = nil; assert(run); run() end
local function ping(id, session)
    enqueue(id, 'version=1\ncommand=ping\nsession=' .. session .. '\nexpires=' .. (os.time()+30) .. '\n')
    tick()
    local response = root .. '/responses/' .. id .. '.json'
    local content = protocol.read(response)
    assert(content:find('"ok":true',1,true)); os.remove(response)
end
bridge.start(api)
local session = state.session
assert(session and next_loop)
ping(string.rep('a',32), session)
-- REAPER must refresh its directory cache after consuming a request.
tick()
assert(next_loop and not io.open(root .. '/responses/' .. string.rep('a',32) .. '.json','rb'))
ping(string.rep('b',32), session)
-- Old-session requests produce a response without killing the worker.
local id = string.rep('c',32)
enqueue(id, 'version=1\ncommand=ping\nsession=stale\nexpires=' .. (os.time()+30) .. '\n')
tick()
assert(protocol.read(root .. '/responses/' .. id .. '.json'):find('"ok":false',1,true))
ping(string.rep('d',32), session)
assert(refreshes >= 5)
local before = next_loop
bridge.start(api) -- idempotent start leaves the existing worker in charge
assert(next_loop == before)
id = string.rep('e',32)
enqueue(id,'version=1\ncommand=stop\nsession=' .. session .. '\nexpires=' .. (os.time()+30) .. '\n')
tick(); assert(not next_loop and not state.session)
assert(protocol.read(root .. '/status.json'):find('"state":"stopped"',1,true))
on_exit()
print('PASS: cached directory refresh, one-time request consumption, stale session rejection, failure recovery, idempotent start and stop')
