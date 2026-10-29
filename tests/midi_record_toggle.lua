local toggle = dofile('lib/midi_record_toggle.lua')

local function fixture()
    local state = { ext = {}, buttons = {}, deferred = {}, exits = {}, watchers = {},
        binary_calls = 0, finishes = {}, messages = {}, command = 101, now = 0 }
    local api = {
        get_action_context = function() return false, '', 0, state.command end,
        GetExtState = function(_, key) return state.ext[key] or '' end,
        SetExtState = function(_, key, value) state.ext[key] = value end,
        DeleteExtState = function(_, key) state.ext[key] = nil end,
        SetToggleCommandState = function(_, command, value) state.buttons[command] = value end,
        RefreshToolbar2 = function() end,
        time_precise = function() state.now = state.now + 1; return state.now end,
        atexit = function(callback) state.exits[#state.exits + 1] = callback end,
        defer = function(callback) state.deferred[#state.deferred + 1] = callback end,
        ShowMessageBox = function(message) state.messages[#state.messages + 1] = message end,
        ShowConsoleMsg = function(message) state.console = message end,
    }
    local services = {
        native = { resolve_binary = function()
            state.binary_calls = state.binary_calls + 1
            if state.missing_binary then error('missing optimizer') end
            return '/optimizer'
        end },
        watcher = { new = function()
            local watcher = { polls = 0 }
            watcher.poll = function()
                watcher.polls = watcher.polls + 1
                local batch = watcher.batch; watcher.batch = nil
                return batch
            end
            state.watchers[#state.watchers + 1] = watcher
            return watcher
        end },
        finish = { run = function(_, root, batch, options)
            assert(root == '/bundle/' and batch.recorded)
            state.finishes[#state.finishes + 1] = options
            return { aligned = 2, optimized = options.optimize_cc and 2 or 0, report = 'complete' }
        end },
    }
    return api, state, services
end

local api, s, services = fixture()
s.missing_binary = true
toggle.start(api, '/bundle/', 'align', services)
assert(s.binary_calls == 0 and s.buttons[101] == 1)
assert(s.watchers[1].polls == 1 and #s.deferred == 1)
s.watchers[1].batch = { recorded = true }
s.deferred[1]()
assert(#s.finishes == 1 and s.finishes[1].optimize_cc == false and s.finishes[1].open_all == true)
assert(s.ext.last_report:find('Align only', 1, true))
toggle.start(api, '/bundle/', 'align', services)
assert(not s.ext.running and s.buttons[101] == 0 and #s.watchers == 1)
local deferred_count, polls = #s.deferred, s.watchers[1].polls
s.deferred[1](); s.exits[1]()
assert(#s.deferred == deferred_count and s.watchers[1].polls == polls and s.buttons[101] == 0)

-- Switching starts a new worker, immediately clears the old button, and
-- prevents the old deferred worker or its exit handler affecting the new mode.
api, s, services = fixture()
toggle.start(api, '/bundle/', 'align', services)
local old_loop, old_exit = s.deferred[1], s.exits[1]
s.command = 202
toggle.start(api, '/bundle/', 'full', services)
local token = s.ext.running
assert(s.buttons[101] == 0 and s.buttons[202] == 1 and s.binary_calls == 1)
local deferred_count = #s.deferred
old_loop(); old_exit()
assert(s.ext.running == token and s.buttons[202] == 1 and #s.deferred == deferred_count)
s.watchers[2].batch = { recorded = true }
s.deferred[2]()
assert(s.finishes[1].optimize_cc == true and s.finishes[1].open_all == true)
assert(s.ext.last_report:find('Align + CC', 1, true))
s.exits[2]()
assert(not s.ext.running and s.buttons[202] == 0)

-- An unavailable optimizer must not disable the running alignment worker.
api, s, services = fixture()
toggle.start(api, '/bundle/', 'align', services)
local token = s.ext.running
s.command = 202; s.missing_binary = true
toggle.start(api, '/bundle/', 'full', services)
assert(s.ext.running == token and s.buttons[101] == 1 and not s.buttons[202])
assert(#s.watchers == 1 and #s.messages == 1 and s.binary_calls == 1)
s.watchers[1].batch = { recorded = true }
s.deferred[1]()
assert(s.finishes[1].optimize_cc == false)

-- Full mode also toggles off without resolving the optimizer a second time.
api, s, services = fixture()
toggle.start(api, '/bundle/', 'full', services)
toggle.start(api, '/bundle/', 'full', services)
assert(s.buttons[101] == 0 and not s.ext.running and s.binary_calls == 1)

print('PASS: recording modes, optimizer independence, mutual exclusion, stale worker isolation, failed preflight, and termination cleanup')
