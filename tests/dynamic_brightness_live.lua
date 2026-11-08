local live = dofile('lib/dynamic_brightness_live.lua')
local base_model = dofile('lib/dynamic_brightness.lua')
local function clone(value)
    if type(value) ~= 'table' then return value end
    local result = {}
    for k, v in pairs(value) do result[k] = clone(v) end
    return result
end
local function approx(a, b) assert(math.abs(a - b) < 1e-8, tostring(a) .. ' ~= ' .. tostring(b)) end
local function fails(fn, text)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(text, 1, true), tostring(err))
end
local function fixture()
    local state = { frequency = 2000, gain = 1, ext = {}, guid = 'owned', alive = true,
        project_open = true, current = 'project', recording = false, envelope = false,
        config = { ['param.0.mod.active'] = '0', ['param.1.mod.active'] = '1',
            ['param.1.mod.baseline'] = '.25', ['param.1.acs.active'] = '1',
            ['param.1.acs.dir'] = '1', ['param.1.acs.stereo'] = '1',
            ['param.1.lfo.active'] = '0', ['param.1.plink.active'] = '0',
            ['param.1.acs.chan'] = '0', ['param.1.acs.strength'] = '.318',
            ['param.1.acs.dblo'] = '-30', ['param.1.acs.dbhi'] = '-12',
            ['param.1.acs.attack'] = '50', ['param.1.acs.release'] = '300' } }
    local metrics = { begin = 0, finish = 0, applies = 0, writes = {}, global = 'original', restores = 0 }
    local chunks, r = {}, {}
    r.EnumProjects = function(i) if i == -1 then return state.current end
        if i == 0 and state.project_open then return 'project' end end
    r.ValidatePtr2 = function(p, t) return p == 'project' and t == 'track' and state.alive end
    r.TrackFX_GetFXGUID = function() return state.guid end
    r.TrackFX_GetNumParams = function() return 2 end
    r.TrackFX_GetEQParam = function(_, _, p) return true, 4, 0, p == 0 and 0 or 1 end
    r.TrackFX_GetFormattedParamValue = function() return true, tostring(state.frequency) .. ' Hz' end
    r.TrackFX_GetParamNormalized = function()
        local db = 20 * math.log(state.gain, 10)
        return .5 + .02 * db + .0001 * db * db
    end
    r.TrackFX_GetParam = function() return state.gain, 0, 4 end
    r.TrackFX_SetEQParam = function(_, _, _, _, kind, value)
        if state.fail_eq then return false end
        if kind == 0 then state.frequency = value else state.gain = value end
        metrics.writes[#metrics.writes + 1] = 'eq.' .. kind
        return true
    end
    r.GetSetMediaTrackInfo_String = function(_, key, value, set)
        if set then state.ext[key] = value end
        return true, state.ext[key] or ''
    end
    r.TrackFX_GetNamedConfigParm = function(_, _, key)
        local value = state.config[key]
        if value and state.round_config and (key == 'param.1.acs.strength' or key == 'param.1.mod.baseline') then
            value = ('%.4f'):format(tonumber(value))
        end
        return value ~= nil, value or ''
    end
    r.TrackFX_SetNamedConfigParm = function(_, _, key, value)
        if state.fail_config then return false end
        state.config[key] = value
        metrics.writes[#metrics.writes + 1] = key
        return true
    end
    r.GetPlayStateEx = function() return state.recording and 4 or 0 end
    r.GetFXEnvelope = function() return state.envelope end
    r.GetTrackStateChunk = function()
        chunks[#chunks + 1] = clone(state)
        return true, tostring(#chunks)
    end
    r.SetTrackStateChunk = function(_, chunk)
        state = clone(chunks[tonumber(chunk)])
        metrics.restores = metrics.restores + 1
        return true
    end
    r.Undo_BeginBlock2 = function() metrics.begin = metrics.begin + 1 end
    r.Undo_EndBlock2 = function() assert(state.project_open); metrics.finish = metrics.finish + 1 end
    r.UpdateArrange = function() end
    r.SetExtState = function(section, key, value, persist)
        assert(section == 'GPhil_DynamicBrightness' and key == 'last_settings_v1' and persist)
        metrics.global = value
    end
    local model = setmetatable({}, { __index = base_model })
    model.find = function() return 0 end
    model.gain_parameter = function() return 1 end
    model.settings = function()
        return base_model.decode(state.ext['P_EXT:GPhil_dynamicBrightnessSettings'] or '') or clone(base_model.defaults)
    end
    model.apply = function(_, _, _, settings)
        metrics.applies = metrics.applies + 1
        live.calibrate(r, 'track', 0, 1)
        local baseline, strength = live.mapping(r, 'track', settings.minimum, settings.maximum)
        state.config['param.1.mod.baseline'], state.config['param.1.acs.strength'] = tostring(baseline), tostring(strength)
    end
    live.calibrate(r, 'track', 0, 1)
    local baseline, strength = live.mapping(r, 'track', -3, 3)
    state.config['param.1.mod.baseline'], state.config['param.1.acs.strength'] = tostring(baseline), tostring(strength)
    state.ext['P_EXT:GPhil_dynamicBrightnessSettings'] = base_model.encode(base_model.defaults)
    metrics.writes = {}
    return live.new(r, model, 'project', 'track'), r, metrics, function() return state end
end

local session, r, metrics, state = fixture()
approx(state().gain, 1)
assert(#metrics.writes == 0 and metrics.global == 'original')
local s = assert(session.read())
approx(s.maximum, 3)
approx(s.minimum, -3)
state().frequency = 2020
state().config['param.1.acs.attack'] = '77'
s = assert(session.read())
assert(s.frequency == 2020 and s.attack == 77 and #metrics.writes == 0)
session.begin()
s.maximum, s.threshold, s.frequency = 1.35, -35, 2500
session.update(s)
local count = #metrics.writes
assert(count == 3 and metrics.global == 'original' and metrics.begin == 1 and metrics.finish == 0)
session.update(s)
assert(#metrics.writes == count, 'Unchanged settings must not write native parameters')
approx(assert(session.read()).maximum, 1.35)
s.maximum = 1.4
session.update(s)
approx(assert(session.read()).maximum, 1.4)
session.finish()
assert(metrics.begin == 1 and metrics.finish == 1 and metrics.applies == 0)
assert(metrics.global == base_model.encode(s)
    and state().ext['P_EXT:GPhil_dynamicBrightnessSettings'] == metrics.global)
for _, key in ipairs(metrics.writes) do
    assert(key ~= 'eq.1' and not key:find('mod%.') and not key:find('lfo'), 'Drag reset modulation/gain')
end
session.close()
assert(metrics.finish == 1)

-- Native values outside the safe range are reported, never silently overwritten.
state().config['param.1.acs.strength'] = '1'
local invalid, err = session.read()
assert(not invalid and err:find('outside 0–12 dB', 1, true))
assert(metrics.global == base_model.encode(s))

-- A failed setter restores the entire original gesture and leaves preferences alone.
session, r, metrics, state = fixture()
s = assert(session.read())
session.begin()
s.frequency = 4000
session.update(s)
state().fail_config = true
s.attack = 80
fails(function() session.update(s) end, 'Could not update native')
assert(state().frequency == 2000 and metrics.restores == 1 and metrics.finish == 1
    and metrics.global == 'original')
session.close()
assert(metrics.finish == 1)

-- Unsafe automation is rejected before a transaction or native write starts.
session, r, metrics, state = fixture()
state().envelope = true
fails(session.begin, 'automation')
assert(metrics.begin == 0 and #metrics.writes == 0)
state().envelope = false
state().config['param.1.mod.baseline'] = '.4'
fails(session.begin, 'outside -12–0 dB')
assert(metrics.begin == 0)

-- Missing calibration upgrades once; repeated gestures use the saved curve.
session, r, metrics, state = fixture()
state().ext['P_EXT:GPhil_dynamicBrightnessGainMapV3'] = nil
state().config['param.1.mod.baseline'] = '.25'
state().config['param.1.acs.strength'] = '.318'
assert(session.read().maximum == 3 and session.read().minimum == 0 and metrics.applies == 0)
session.begin(); session.finish(); session.begin(); session.finish()
assert(metrics.applies == 1 and metrics.begin == 2 and metrics.finish == 2)

-- Switching project rolls back the original gesture; replacing FX never restores over it.
session, r, metrics, state = fixture()
s = assert(session.read()); session.begin(); s.frequency = 3000; session.update(s)
state().current = 'other-project'
s.frequency = 3500
fails(function() session.update(s) end, 'active project changed')
assert(metrics.restores == 1 and metrics.finish == 1 and metrics.global == 'original')
session, r, metrics, state = fixture()
s = assert(session.read()); session.begin(); state().guid = 'replacement'
s.frequency = 3000
fails(function() session.update(s) end, 'replaced')
assert(metrics.restores == 0 and metrics.finish == 1 and #metrics.writes == 0)

-- Closing a tab during a drag cannot call an undo API with a destroyed pointer.
session, r, metrics, state = fixture()
session.begin(); state().project_open = false
session.close(); session.close()
assert(metrics.finish == 0 and metrics.global == 'original')

-- Native ACS reads round to four decimals, including upward at the +3 dB cap.
session, r, metrics, state = fixture()
local curve, raw = {}, {}
for i = -120, 120 do
    local db = i / 10
    curve[#curve + 1] = ('%.17g'):format(.5 + .01897057917955188 * db + .001316058324743192 * db * math.abs(db))
    raw[#raw + 1] = ('%.17g'):format(10 ^ (db / 20) / 4)
end
state().ext['P_EXT:GPhil_dynamicBrightnessGainMapV3'] = table.concat(curve, ',') .. ';' .. table.concat(raw, ',')
state().round_config = true
state().config['param.1.mod.baseline'] = '.25'
state().config['param.1.acs.strength'] = '.06875626246134436'
approx(assert(session.read()).maximum, 3)
state().config['param.1.acs.strength'] = '.031417'
approx(assert(session.read()).maximum, 1.5)
for _ = 1, 10 do approx(assert(session.read()).maximum, 1.5) end
local typed = clone(base_model.defaults)
typed.maximum, typed.minimum = 1.357, -1.357
state().ext['P_EXT:GPhil_dynamicBrightnessSettings'] = base_model.encode(typed)
local typed_baseline, typed_strength = live.mapping(r, 'track', typed.minimum, typed.maximum)
state().config['param.1.mod.baseline'], state().config['param.1.acs.strength'] = tostring(typed_baseline), tostring(typed_strength)
approx(assert(session.read()).maximum, typed.maximum)
approx(assert(session.read()).minimum, typed.minimum)
state().config['param.1.mod.baseline'] = '.25'
state().config['param.1.acs.strength'] = tostring(.01897057917955188 * 12.1 + .001316058324743192 * 12.1 ^ 2)
invalid, err = session.read()
assert(not invalid and err:find('outside 0–12 dB', 1, true))

-- Minimum changes update the baseline and strength together, without disabling modulation.
session, r, metrics, state = fixture()
s = assert(session.read()); s.minimum = -1.5; s.maximum = 1.5
session.update(s)
assert(#metrics.writes == 2 and metrics.begin == 1)
local expected_baseline, expected_strength = live.mapping(r, 'track', -1.5, 1.5)
approx(tonumber(state().config['param.1.mod.baseline']), expected_baseline)
approx(tonumber(state().config['param.1.acs.strength']), expected_strength)
assert(state().config['param.1.mod.active'] == '1')
state().round_config = true
approx(assert(session.read()).minimum, -1.5)
approx(assert(session.read()).maximum, 1.5)
session.finish()
assert(base_model.decode(metrics.global).minimum == -1.5)
state().config['param.1.mod.baseline'] = tostring(10 ^ (-12.1 / 20) / 4)
invalid, err = session.read()
assert(not invalid and err:find('outside -12–0 dB', 1, true))
fails(function() live.mapping(r, 'track', -12.1, 3) end, 'Minimum shelf gain')
fails(function() live.mapping(r, 'track', -3, 12.1) end, 'Maximum shelf gain')

-- Full configurable limits include ±12; factory defaults remain ±3.
session, r, metrics, state = fixture()
assert(session.read().minimum == -3 and session.read().maximum == 3)
s = assert(session.read()); s.minimum, s.maximum = -12, 12
session.update(s); session.finish()
state().round_config = true
approx(assert(session.read()).minimum, -12)
approx(assert(session.read()).maximum, 12)
assert(base_model.decode(metrics.global).minimum == -12 and base_model.decode(metrics.global).maximum == 12)
-- External baseline moves near -12 must account for raw/automation taper differences.
for _, cut in ipairs({ -11.653, -11.327, -8.793 }) do
    local baseline, strength = live.mapping(r, 'track', cut, 12)
    state().config['param.1.mod.baseline'], state().config['param.1.acs.strength'] = tostring(baseline), tostring(strength)
    local external = assert(session.read())
    assert(math.abs(external.minimum - cut) <= .02)
    approx(external.maximum, 12)
end

-- A V2 project retains its native cut/boost while upgrading once to V3.
session, r, metrics, state = fixture()
local norm_csv, raw_csv = state().ext['P_EXT:GPhil_dynamicBrightnessGainMapV3']:match('^([^;]+);([^;]+)$')
local function middle(csv)
    local values = {}
    for part in csv:gmatch('[^,]+') do values[#values + 1] = part end
    local result = {}
    for i = 91, 151 do result[#result + 1] = values[i] end
    return table.concat(result, ',')
end
state().ext['P_EXT:GPhil_dynamicBrightnessGainMapV2'] = middle(norm_csv) .. ';' .. middle(raw_csv)
state().ext['P_EXT:GPhil_dynamicBrightnessGainMapV3'] = nil
state().round_config = true
approx(assert(session.read()).minimum, -3); approx(assert(session.read()).maximum, 3)
assert(metrics.applies == 0)
session.begin(); session.finish(); session.begin(); session.finish()
assert(metrics.applies == 1 and state().ext['P_EXT:GPhil_dynamicBrightnessGainMapV3'])
approx(assert(session.read()).minimum, -3); approx(assert(session.read()).maximum, 3)
print('dynamic brightness live: passed')
