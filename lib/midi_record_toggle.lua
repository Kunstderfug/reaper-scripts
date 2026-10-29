-- Shared lifecycle for mutually exclusive recording preparation modes.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local namespace = 'GPhil_PrepareRecordedMidi'

function M.start(api, root, mode, services)
    assert(mode == 'align' or mode == 'full', 'Unknown MIDI preparation mode.')
    local watcher_module = services and services.watcher or dofile(here .. 'midi_record_watch.lua')
    local finish = services and services.finish or dofile(here .. 'midi_record_finish.lua')
    local native = services and services.native or dofile(here .. 'cc_native.lua')
    local _, _, section, command = api.get_action_context()
    local function get(key) return api.GetExtState(namespace, key) end
    local function set(key, value) api.SetExtState(namespace, key, tostring(value), false) end
    local function button(s, c, value)
        api.SetToggleCommandState(s, c, value)
        api.RefreshToolbar2(s, c)
    end
    local running = get('running') ~= ''
    local previous_mode = get('mode')
    if running and (previous_mode == mode or (previous_mode == '' and mode == 'full')) then
        api.DeleteExtState(namespace, 'running', false)
        button(section, command, 0)
        return
    end
    -- Alignment alone has no native optimizer dependency. A failed full-mode
    -- preflight leaves an already running alignment mode enabled.
    if mode == 'full' then
        local ok, err = pcall(native.resolve_binary, api, root)
        if not ok then api.ShowMessageBox(tostring(err), 'Prepare recorded MIDI', 0); return end
    end
    if running then
        local previous_section, previous_command = tonumber(get('section')), tonumber(get('command'))
        if previous_section and previous_command then button(previous_section, previous_command, 0) end
    end
    local watcher = watcher_module.new(api)
    local token = mode .. ':' .. tostring(api.time_precise()) .. ':' .. tostring(command)
    set('running', token); set('mode', mode); set('section', section); set('command', command)
    button(section, command, 1)
    api.atexit(function()
        -- A replaced worker must never clear the new worker's toolbar state.
        if get('running') == token then
            api.DeleteExtState(namespace, 'running', false)
            button(section, command, 0)
        end
    end)
    local function loop()
        if get('running') ~= token then return end
        local ok, err = xpcall(function()
            local batch = watcher.poll()
            if batch then
                local result = finish.run(api, root, batch, { optimize_cc = mode == 'full', open_all = true })
                if result then
                    local report = string.format('%s: %d item edges aligned; %d MIDI sources optimized.\n%s',
                        mode == 'align' and 'Align only' or 'Align + CC', result.aligned, result.optimized, result.report)
                    set('last_report', report)
                    api.ShowConsoleMsg('Recorded MIDI: ' .. report .. '\n')
                end
            end
        end, debug.traceback)
        if not ok then
            set('last_report', err)
            api.ShowConsoleMsg('Recorded MIDI preparation failed:\n' .. tostring(err) .. '\n')
        end
        api.defer(loop)
    end
    -- Establish the idle snapshot before returning control to REAPER.
    loop()
end
return M
