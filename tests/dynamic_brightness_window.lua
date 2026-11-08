-- Input/state tests without a native window; DSP is covered by the native fixture.
local real_dofile = dofile
local model = real_dofile('lib/dynamic_brightness.lua')
local function copy(s) return assert(model.decode(model.encode(s))) end

-- Existing projects own their settings; new projects use the last successful setup.
local project_csv, last_csv = '', model.encode({ frequency = 4000, maximum = 1.7,
    threshold = -35, ceiling = -15, attack = 65, release = 450, minimum = -1.7 })
local settings_api = {
    GetSetMediaTrackInfo_String = function() return true, project_csv end,
    GetExtState = function(section, key)
        assert(section == 'GPhil_DynamicBrightness' and key == 'last_settings_v1')
        return last_csv
    end,
}
assert(model.settings(settings_api, {}).frequency == 4000)
assert(model.settings(settings_api, {}).minimum == -1.7)
project_csv = model.encode(model.defaults)
assert(model.settings(settings_api, {}).frequency == model.defaults.frequency)
project_csv, last_csv = 'bad data', 'bad data'
assert(model.settings(settings_api, {}).maximum == model.defaults.maximum)

local function session(initial_fx)
    local project, other_project, track = {}, {}, {}
    local state = { fx = initial_fx, project = project, valid = true, applied = {},
        enabled = true, shown = {}, toggled = {}, messages = {}, ext = {}, now = 0,
        delta = false, delta_supported = true, delta_writes = {},
        live_updates = {}, live_finishes = 0, live_begins = 0, drawn = {},
        native = copy(model.defaults), formatted_gain = '1.25', rectangles = {} }
    local saved = copy(model.defaults)
    local fake_model = setmetatable({
        target = function(_, p) assert(p == project); return track end,
        settings = function() return copy(saved) end,
        find = function(_, tr) assert(tr == track); return state.fx end,
        gain_parameter = function(_, tr, fx)
            assert(tr == track and fx == state.fx); return 10
        end,
        delta = function(_, tr)
            assert(tr == track and state.project == project and state.valid)
            return state.delta, state.fx ~= nil and state.delta_supported
        end,
        set_delta = function(_, p, tr, enabled)
            assert(state.project == project and state.valid and p == project and tr == track)
            assert(state.fx ~= nil and state.delta_supported)
            state.delta = enabled
            state.delta_writes[#state.delta_writes + 1] = { fx = state.fx, enabled = enabled }
        end,
        apply = function(_, p, tr, s)
            assert(state.project == project and state.valid and p == project and tr == track)
            model.validate(s)
            state.applied[#state.applied + 1] = copy(s)
            saved, state.native = copy(s), copy(s)
            state.fx = state.fx or 7
            return { fx = state.fx, param = 10 }
        end,
    }, { __index = model })
    local fake_live = { new = function()
        local transaction = false
        local result = {}
        function result.read()
            if not state.fx then return nil, 'Brightness EQ missing' end
            return copy(state.native)
        end
        function result.begin()
            assert(state.project == project and state.valid and state.fx)
            if not transaction then
                transaction = true; state.live_begins = state.live_begins + 1
            end
        end
        function result.update(settings)
            model.validate(settings)
            result.begin()
            state.native = copy(settings)
            state.live_updates[#state.live_updates + 1] = copy(settings)
        end
        function result.finish()
            if transaction then
                transaction = false
                saved = copy(state.native)
                state.applied[#state.applied + 1] = copy(saved)
                state.live_finishes = state.live_finishes + 1
            end
        end
        result.close = result.finish
        return result
    end }
    local api = {
        EnumProjects = function() return state.project end,
        ValidatePtr2 = function(p, tr) assert(p == project and tr == track); return state.valid end,
        GetTrackName = function(tr) assert(tr == track); return true, 'BUS' end,
        GetExtState = function(section, key) return state.ext[section .. '/' .. key] or '' end,
        SetExtState = function(section, key, value, persist)
            assert(persist); state.ext[section .. '/' .. key] = value
        end,
        TrackFX_GetEnabled = function(tr, fx) assert(tr == track); return state.enabled end,
        TrackFX_SetEnabled = function(tr, fx, enabled)
            assert(tr == track and fx == state.fx)
            state.enabled = enabled; state.toggled[#state.toggled + 1] = fx
        end,
        TrackFX_Show = function(tr, fx, mode)
            assert(tr == track and fx == state.fx and mode == 3, 'Open only the floating EQ')
            state.shown[#state.shown + 1] = fx
        end,
        TrackFX_GetFormattedParamValue = function() return true, state.formatted_gain end,
        Undo_BeginBlock2 = function(p) assert(p == project) end,
        Undo_EndBlock2 = function(p) assert(p == project) end,
        time_precise = function() return state.now end,
        atexit = function(fn) state.on_exit = fn end,
        defer = function(fn) state.next_frame = fn end,
        ShowMessageBox = function(message) state.messages[#state.messages + 1] = message end,
    }
    local g = { w = 660, h = 530, mouse_x = 0, mouse_y = 0, mouse_cap = 0 }
    for _, name in ipairs({ 'set', 'setfont', 'update' }) do g[name] = function() end end
    g.rect = function(x, y, width, height)
        assert(width >= 0 and height >= 0, 'Drawing dimensions must not become negative')
        state.rectangles[#state.rectangles + 1] = { x = x, y = y, width = width, height = height }
    end
    g.drawstr = function(text) state.drawn[('%.0f,%.0f'):format(g.x, g.y)] = text end
    g.measurestr = function(s) return #s * 7, 15 end
    g.getchar = function() return state.key or 0 end
    g.showmenu = function() return state.menu_choice or 0 end
    g.init = function(_, w, h) g.w, g.h = w, h end
    g.quit = function() state.closed = true end
    dofile = function(path)
        if path:match('[/\\]dynamic_brightness%.lua$') then return fake_model end
        if path:match('[/\\]dynamic_brightness_live%.lua$') then return fake_live end
        return real_dofile(path)
    end
    local ok, window = pcall(real_dofile, 'lib/dynamic_brightness_window.lua')
    dofile = real_dofile
    assert(ok, window)
    window.open(api, g)
    function state.step(key, x, y, cap)
        state.key = key or 0
        state.drawn, state.rectangles = {}, {}
        if x then g.mouse_x, g.mouse_y = x, y end
        g.mouse_cap = cap or 0
        local next_frame = state.next_frame
        state.next_frame = nil
        assert(next_frame, 'Window stopped scheduling frames')
        next_frame()
        assert(#state.messages == 0, state.messages[1])
    end
    function state.click(x, y) state.step(0, x, y, 1); state.step(0, x, y, 0) end
    function state.type(text)
        for _, cp in utf8.codes(text) do state.step(cp) end
    end
    function state.switch_project() state.project = other_project end
    function state.restore_project() state.project = project end
    function state.field(index)
        return state.drawn['508,' .. (165 + (index - 1) * 32)]
    end
    return state
end

local s = session(3)
assert(#s.applied == 0, 'Opening an existing EQ must not reset it')
s.step(0, 332, 210, 1) -- halfway along Boost limit
assert(#s.applied == 0 and #s.live_updates == 1 and s.native.maximum == 6,
    'Dragging must preview immediately without finishing the gesture')
s.step(0, 332, 210, 0)
assert(#s.applied == 1 and s.applied[1].maximum == 6
    and s.live_begins == 1 and s.live_finishes == 1)
s.click(525, 210)
s.type('2.4')
assert(#s.applied == 1)
s.step(13)
assert(#s.applied == 2 and s.applied[2].maximum == 2.4)
s.click(525, 210)
s.type('99')
s.step(13)
assert(#s.applied == 2, 'Invalid fields must not apply')
s.step(27) -- restore the saved field
s.click(500, 470)
assert(#s.applied == 3 and s.applied[3].maximum == 2.4)

-- A bound window must never edit another project or a removed target track.
s.switch_project()
s.click(500, 470)
s.click(50, 115)
s.click(180, 115)
assert(#s.applied == 3 and #s.toggled == 0 and #s.delta_writes == 0)
s.restore_project()
s.valid = false
s.click(500, 470)
s.click(180, 115)
assert(#s.applied == 3 and #s.delta_writes == 0)
s.valid = true

-- Resolve ownership at button activation, even inside the polling interval.
s.fx = 8
s.click(470, 40)
assert(s.shown[#s.shown] == 8)
s.fx = 9
s.click(50, 115)
assert(s.toggled[#s.toggled] == 9 and not s.enabled)
s.fx = 10
s.click(180, 115)
assert(#s.delta_writes == 0, 'Enable the EQ before starting Delta audition')
s.click(50, 115)
s.click(180, 115)
assert(s.delta and #s.delta_writes == 1 and s.delta_writes[1].fx == 10)
s.click(180, 115)
assert(not s.delta and #s.delta_writes == 2)
s.delta_supported = false
s.click(180, 115)
assert(#s.delta_writes == 2, 'Unsupported Delta must be disabled')
s.delta_supported = true
s.fx = nil
s.click(180, 115)
assert(#s.delta_writes == 2, 'A removed EQ cannot be auditioned')
s.fx = 10

-- Factory presets apply, and user names remain valid UTF-8 at the byte limit.
s.menu_choice = 2
s.click(100, 410)
assert(s.applied[#s.applied].maximum == 2)
assert(s.applied[#s.applied].minimum == -2, 'Balanced preset must include its lower cut limit')
s.click(380, 410)
s.step(1) -- replace the preset name
s.type(string.rep('a', 59))
s.type('🎹') -- four bytes cannot fit; must not leave a partial character
s.step(8)
s.type('é') -- now exactly sixty bytes
s.step(13)
assert(s.ext['GPhil_DynamicBrightness/presets_v1']:find(':' .. model.encode(s.applied[#s.applied]), 1, true))
local preset_data = s.ext['GPhil_DynamicBrightness/presets_v1']
local encoded_name = preset_data:match('^([^:]+):')
local decoded_name = encoded_name:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)
assert(utf8.len(decoded_name) == 59 and #decoded_name == 60)
s.step(27)
assert(s.closed)

local new = session(nil)
assert(#new.applied == 1 and new.fx == 7, 'First open creates one missing EQ')

-- External ReaEQ edits update idle fields; pending typed edits remain intact.
local sync = session(3)
sync.native.frequency, sync.now = 4500, .3
sync.step()
assert(sync.field(1) == '4500', 'Idle fields must follow native frequency changes')
sync.click(525, 170)
sync.type('2013.5')
sync.native.frequency, sync.now = 8000, .6
sync.step()
assert(sync.field(1) == '2013.5|', 'Polling must preserve a pending typed value')
sync.click(20, 70) -- lose focus but retain the pending edit
sync.native.frequency, sync.now = 7000, .9
sync.step()
assert(sync.field(1) == '2013.5', 'Uncommitted values must survive focus loss')
sync.click(500, 470)
assert(sync.native.frequency == 2013.5, 'Typed values must remain exact, without slider snap/quantization')
sync.native.frequency, sync.now = 6100, 1.2
sync.step()
assert(sync.field(1) == '6100', 'Polling must resume after applying an edit')
sync.click(525, 170)
sync.type('5200')
sync.native.frequency = 6200
sync.step(27)
assert(sync.field(1) == '6200', 'Escape must restore current native value, not stale saved settings')
sync.native.frequency, sync.now = 6400, 1.5
sync.step()
assert(sync.field(1) == '6400', 'Cancelling the only edit must unblock native polling')

-- Frequency defaults are logarithmic: 2000 Hz is 72 px into the 288 px range.
-- Capture within 6 px, hold through 10 px, and release beyond that distance.
local snap = session(3)
snap.native.frequency, snap.now = 4000, .3
snap.step()
snap.step(0, 188 + 72 + 5, 170, 1)
assert(snap.native.frequency == 2000 and snap.live_finishes == 0)
snap.step(0, 188 + 72 + 9, 170, 1)
assert(snap.native.frequency == 2000, 'Default snap must hold inside its hysteresis distance')
snap.step(0, 188 + 72 + 11, 170, 1)
assert(snap.native.frequency > 2000, 'Dragging past hysteresis must release the default')
snap.step(0, 188 + 72 + 11, 170, 0)
assert(snap.live_begins == 1 and snap.live_finishes == 1)
snap.click(525, 170)
snap.type('2013.5')
snap.step(13)
assert(snap.native.frequency == 2013.5, 'Typing near the default must not snap')
snap.native.maximum, snap.now = 2.4, .6
snap.step()
snap.click(188 + 72 + 4, 210)
assert(snap.native.maximum == 3, 'The boost-limit default must also capture near its marker')
snap.click(525, 210)
snap.type('2.98')
snap.step(13)
assert(snap.native.maximum == 2.98, 'Typed boost values must not snap to the default')
snap.click(525, 210)
snap.type('12')
snap.step(13)
assert(snap.native.maximum == 12, 'The default boost is not a hard limit')
snap.click(525, 210)
snap.type('12.01')
snap.step(13)
assert(snap.native.maximum == 12, 'Values above the supported boost range must not apply')
snap.step(27)

-- Bidirectional controls use negative cut limits, including native sync and
-- default snapping; the signed live meter must display cuts as negative gain.
local cut = session(3)
cut.native.minimum, cut.formatted_gain, cut.now = -1.2, '-1.5', .3
cut.step()
assert(cut.field(3) == '-1.2', 'Cut limit must follow the native settings')
assert(cut.drawn['285,109']:find('-1.5', 1, true), 'Live meter must show the signed negative gain')
cut.click(188 + 216 + 4, 238)
assert(cut.native.minimum == -3, 'The cut-limit default must soft-snap near its marker')
cut.click(525, 238)
cut.type('-2.98')
cut.step(13)
assert(cut.native.minimum == -2.98, 'Typed cut limits must remain exact')
cut.click(525, 238)
cut.type('-12')
cut.step(13)
assert(cut.native.minimum == -12, 'The default cut is not a hard limit')
cut.click(525, 238)
cut.type('-12.01')
cut.step(13)
assert(cut.native.minimum == -12, 'Cuts outside the supported range must not apply')
cut.step(27)
cut.native.minimum, cut.now = -.5, .6
cut.step()
assert(cut.field(3) == '-0.5', 'Cut-limit synchronization must resume after cancelling invalid input')

-- The real model resolves the owned FX and uses the Delta identifier, with
-- a balanced undo block and no parameter write when automation owns Delta.
local delta_state = { value = 0, param = 17, writes = 0, undo = 0, owned = true }
local delta_api = {
    GetSetMediaTrackInfo_String = function() return true, delta_state.owned and '{owned}' or '' end,
    TrackFX_GetCount = function() return 1 end,
    TrackFX_GetFXGUID = function() return '{owned}' end,
    TrackFX_GetParamFromIdent = function(_, fx, ident)
        assert(fx == 0 and ident == ':delta'); return delta_state.param
    end,
    TrackFX_GetParam = function(_, fx, param)
        assert(fx == 0 and param == 17); return delta_state.value
    end,
    GetFXEnvelope = function(_, fx, param, create)
        assert(fx == 0 and param == 17 and not create); return delta_state.envelope
    end,
    TrackFX_SetParamNormalized = function(_, fx, param, value)
        assert(fx == 0 and param == 17)
        delta_state.value, delta_state.writes = value, delta_state.writes + 1
        return true
    end,
    Undo_BeginBlock2 = function() delta_state.undo = delta_state.undo + 1 end,
    Undo_EndBlock2 = function() delta_state.undo = delta_state.undo - 1 end,
}
local delta, supported = model.delta(delta_api, {})
assert(not delta and supported)
model.set_delta(delta_api, {}, {}, true)
assert(model.delta(delta_api, {}) and delta_state.value == 1 and delta_state.undo == 0)
model.set_delta(delta_api, {}, {}, false)
assert(not model.delta(delta_api, {}) and delta_state.value == 0 and delta_state.writes == 2)
delta_state.envelope = {}
assert(not pcall(model.set_delta, delta_api, {}, {}, true) and delta_state.writes == 2)
delta_state.envelope, delta_state.param = nil, -1
delta, supported = model.delta(delta_api, {})
assert(not delta and not supported)
assert(not pcall(model.set_delta, delta_api, {}, {}, true) and delta_state.writes == 2)
delta_state.owned = false
assert(not pcall(model.set_delta, delta_api, {}, {}, true) and delta_state.undo == 0)
print('dynamic brightness window: passed')
