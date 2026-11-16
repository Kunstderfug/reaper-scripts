-- Serialized local mailbox service running on REAPER's main thread.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local p = dofile(here .. 'native_bridge_protocol.lua')
local clicks = dofile(here .. 'native_click_export.lua')
local namespace = 'GPhil_NativeBridge'
function M.start(api)
    local prior = tonumber(api.GetExtState(namespace, 'heartbeat')) or 0
    if api.GetExtState(namespace, 'session') ~= '' and os.time() - prior < 5 then return end
    local root = api.GetResourcePath() .. '/GPhilBridge'
    for _, dir in ipairs({'', '/inbox', '/responses'}) do api.RecursiveCreateDirectory(root .. dir, 0) end
    local session = api.genGuid():gsub('[^%w]', '')
    api.SetExtState(namespace, 'session', session, false)
    local alive, last_poll, last_heartbeat = true, -1, -1
    local function status(state)
        api.SetExtState(namespace, 'heartbeat', tostring(os.time()), false)
        p.write(root .. '/status.json', p.json({version=1, session=session, state=state,
            heartbeat=os.time(), reaperVersion=api.GetAppVersion(), mailbox=root}) .. '\n')
    end
    api.atexit(function()
        if api.GetExtState(namespace, 'session') == session then
            api.DeleteExtState(namespace, 'session', false)
            pcall(status, 'stopped')
        end
    end)
    local allowed = {version=true, session=true, expires=true, command=true, project=true,
        open_project=true, output=true, region=true, grid_only=true}
    local function process(file, id)
        local ok, result = xpcall(function()
            local request = p.parse(p.read(file))
            for key in pairs(request) do assert(allowed[key], 'Unknown request field: ' .. key) end
            assert(request.session == session, 'Request belongs to another bridge session')
            local expires = tonumber(request.expires)
            assert(expires and expires >= os.time() and expires <= os.time() + 300, 'Expired/invalid request deadline')
            if request.command == 'ping' then return {session=session, reaperVersion=api.GetAppVersion()} end
            if request.command == 'projects' then return {projects=clicks.projects(api)} end
            if request.command == 'stop' then alive = false; return {stopped=true} end
            assert(request.command == 'export-clicks', 'Unknown bridge command')
            assert(request.output and request.output:sub(1, 1) == '/', 'Output must be absolute')
            request.output = request.output .. '/' .. id
            return clicks.run(api, request)
        end, debug.traceback)
        p.write(root .. '/responses/' .. id .. '.json', p.json({version=1, id=id,
            session=session, ok=ok, result=ok and result or nil, error=not ok and tostring(result) or nil}) .. '\n')
        os.remove(file)
    end
    local function poll()
        if api.GetExtState(namespace, 'session') ~= session then return end
        local now = api.time_precise()
        local ok, err = xpcall(function()
            if now - last_heartbeat >= 1 then status('running'); last_heartbeat = now end
            if now - last_poll >= 0.2 then
                last_poll = now
                -- One request per poll keeps REAPER responsive and serializes tab ownership.
                api.EnumerateFiles(root .. '/inbox', -1) -- REAPER caches directory listings.
                for i = 0, 10000 do
                    local name = api.EnumerateFiles(root .. '/inbox', i)
                    if not name then break end
                    local id = name:match('^([a-f0-9]+)%.request$')
                    if id and #id == 32 then
                        local file = root .. '/inbox/' .. name
                        local claimed = file .. '.working'
                        if os.rename(file, claimed) then process(claimed, id) end
                        break
                    end
                end
            end
        end, debug.traceback)
        if not ok then
            api.ShowConsoleMsg('GPhil native bridge stopped: ' .. tostring(err) .. '\n')
            alive = false
        end
        if alive then api.defer(poll)
        else
            api.DeleteExtState(namespace, 'session', false)
            pcall(status, 'stopped')
        end
    end
    poll()
end
return M
