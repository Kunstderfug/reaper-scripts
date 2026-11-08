-- Native parameter synchronization and one undo transaction per GFX gesture.
local M = {}
local map_key = 'P_EXT:GPhil_dynamicBrightnessGainMapV3'
local previous_map_key = 'P_EXT:GPhil_dynamicBrightnessGainMapV2'
local legacy_map_key = 'P_EXT:GPhil_dynamicBrightnessGainMap'
local settings_key = 'P_EXT:GPhil_dynamicBrightnessSettings'
-- REAPER reports named ACS values with four decimal places.
local strength_precision = .0000501

local function decode_curve(csv, count)
    local curve = {}
    for part in (csv .. ','):gmatch('(.-),') do
        local n = tonumber(part)
        if not n or n ~= n or n < 0 or n > 1 or (#curve > 0 and n <= curve[#curve]) then return end
        curve[#curve + 1] = n
    end
    if #curve == count then return curve end
end

local function decode_map(csv, count, origin)
    local normalized, raw = csv:match('^([^;]+);([^;]+)$')
    if not normalized then return end
    normalized, raw = decode_curve(normalized, count), decode_curve(raw, count)
    if normalized and raw then return { normalized = normalized, raw = raw, origin = origin } end
end

local function read_map(r, track)
    local _, csv = r.GetSetMediaTrackInfo_String(track, map_key, '', false)
    return decode_map(csv or '', 241, -12)
end

local function previous_map(r, track)
    local _, csv = r.GetSetMediaTrackInfo_String(track, previous_map_key, '', false)
    return decode_map(csv or '', 61, -3)
end

function M.calibrate(r, track, fx, param)
    local values, raw_values = {}, {}
    local ok, err = pcall(function()
        for i = -120, 120 do
            assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 1, 10 ^ (i / 200), false),
                'Could not calibrate the native shelf gain.')
            values[#values + 1] = ('%.17g'):format(r.TrackFX_GetParamNormalized(track, fx, param))
            local raw, minimum, maximum = r.TrackFX_GetParam(track, fx, param)
            assert(maximum > minimum, 'The native shelf raw gain range is invalid.')
            raw_values[#raw_values + 1] = ('%.17g'):format((raw - minimum) / (maximum - minimum))
        end
    end)
    assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 1, 1, false), 'Could not restore unity after gain calibration.')
    if not ok then error(err, 0) end
    local csv = table.concat(values, ',') .. ';' .. table.concat(raw_values, ',')
    assert(decode_map(csv, 241, -12), 'The native shelf gain curves are invalid.')
    assert(r.GetSetMediaTrackInfo_String(track, map_key, csv, true), 'Could not save gain calibration.')
    return csv
end

local function gain_at(curve, db, origin)
    local position = (db - (origin or -12)) * 10
    local index = math.min(#curve - 2, math.max(0, math.floor(position)))
    return curve[index + 1] + (curve[index + 2] - curve[index + 1]) * (position - index)
end

local function gain_db(curve, normalized, minimum, maximum, epsilon, origin, exact)
    origin = origin or -12
    epsilon = epsilon or strength_precision
    local low, high = gain_at(curve, minimum, origin), gain_at(curve, maximum, origin)
    assert(normalized >= low - epsilon and normalized <= high + epsilon,
        'Native shelf range is outside ' .. minimum .. '–' .. maximum .. ' dB. Restore the bounded EQ setup.')
    normalized = math.max(low, math.min(high, normalized))
    for i = 2, #curve do
        if normalized <= curve[i] then
            local db = origin + (i - 2 + (normalized - curve[i - 1]) / (curve[i] - curve[i - 1])) / 10
            return exact and db or math.floor(db * 100 + .5) / 100
        end
    end
    return maximum
end

function M.mapping(r, track, minimum, maximum)
    assert(type(minimum) == 'number' and minimum >= -12 and minimum <= 0, 'Minimum shelf gain must be -12–0 dB.')
    assert(type(maximum) == 'number' and maximum >= 0 and maximum <= 12, 'Maximum shelf gain must be 0–12 dB.')
    local map = assert(read_map(r, track), 'Gain calibration is missing. Reapply the brightness EQ setup.')
    return gain_at(map.raw, minimum), gain_at(map.normalized, maximum) - gain_at(map.normalized, minimum)
end

function M.new(r, model, project, track)
    local session, transaction, original_guid = {}, nil, nil
    local function project_open()
        local i = 0
        while true do
            local candidate = r.EnumProjects(i, '')
            if not candidate then return false end
            if candidate == project then return true end
            i = i + 1
        end
    end
    local function identity()
        assert(project_open(), 'The brightness project was closed.')
        assert(r.ValidatePtr2(project, track, 'MediaTrack*'), 'The brightness track was removed or changed projects.')
        local fx = assert(model.find(r, track), 'The brightness EQ was removed. Create it again first.')
        local guid = r.TrackFX_GetFXGUID(track, fx)
        if original_guid then assert(guid == original_guid, 'The brightness EQ was replaced. Reopen the window.') end
        original_guid = guid
        return fx, model.gain_parameter(r, track, fx)
    end
    local function curve()
        return read_map(r, track)
    end
    local function config(fx, param, suffix)
        local found, value = r.TrackFX_GetNamedConfigParm(track, fx, 'param.' .. param .. '.' .. suffix)
        value = found and tonumber(value)
        assert(value and value == value, 'Cannot read native brightness ' .. suffix .. '.')
        return value
    end
    local function safety(fx, param)
        assert(r.GetPlayStateEx(project) & 4 == 0, 'Stop recording before changing the EQ.')
        for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
            assert(not r.GetFXEnvelope(track, fx, p, false),
                'The brightness EQ has automation. Remove its envelopes before changing it here.')
            local found, active = r.TrackFX_GetNamedConfigParm(track, fx, 'param.' .. p .. '.mod.active')
            assert(p == param or not found or tonumber(active) ~= 1,
                'The brightness EQ has extra parameter modulation. Restore its bounded setup.')
        end
        for _, suffix in ipairs({ 'mod.active', 'acs.active', 'acs.dir', 'acs.stereo' }) do
            assert(config(fx, param, suffix) == 1, 'Native brightness follower settings changed. Restore its bounded setup.')
        end
        for _, suffix in ipairs({ 'lfo.active', 'plink.active', 'acs.chan' }) do
            assert(config(fx, param, suffix) == 0, 'Native brightness follower settings changed. Restore its bounded setup.')
        end
        local map = curve() or previous_map(r, track)
        if map then
            gain_db(map.raw, config(fx, param, 'mod.baseline'), map.origin, 0, strength_precision, map.origin)
        else
            assert(math.abs(config(fx, param, 'mod.baseline') - .25) <= strength_precision,
                'Native shelf baseline changed. Restore the bounded EQ setup.')
        end
    end
    local function native_read()
        local fx, param = identity()
        local frequency
        for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
            local eq, band, index, kind = r.TrackFX_GetEQParam(track, fx, p)
            if eq and band == 4 and index == 0 and kind == 0 then
                local found, formatted = r.TrackFX_GetFormattedParamValue(track, fx, p, '')
                assert(found, 'Cannot read native shelf frequency.')
                formatted = formatted:lower():gsub(',', '')
                frequency = tonumber(formatted:match('([%d%.]+)'))
                if frequency and formatted:find('k', 1, true) then frequency = frequency * 1000 end
                break
            end
        end
        assert(frequency, 'Cannot read native shelf frequency.')
        local map = curve() or previous_map(r, track)
        local stored = transaction and transaction.settings or model.settings(r, track)
        local minimum, maximum = 0, stored.maximum
        local strength = config(fx, param, 'acs.strength')
        if map then
            local baseline = config(fx, param, 'mod.baseline')
            minimum = gain_db(map.raw, baseline, map.origin, 0, strength_precision, map.origin)
            if stored.minimum and stored.minimum >= map.origin
                and math.abs(baseline - gain_at(map.raw, stored.minimum, map.origin)) <= strength_precision then
                minimum = stored.minimum
            end
            -- Propagate raw-baseline rounding through its separate gain taper.
            -- Near -12 dB its uncertainty is larger than at unity.
            local low_min = gain_db(map.raw, baseline - strength_precision, map.origin, 0,
                2 * strength_precision, map.origin, true)
            local high_min = gain_db(map.raw, baseline + strength_precision, map.origin, 0,
                2 * strength_precision, map.origin, true)
            local minimum_norm = gain_at(map.normalized, minimum, map.origin)
            local endpoint_precision = strength_precision + math.max(
                math.abs(minimum_norm - gain_at(map.normalized, low_min, map.origin)),
                math.abs(minimum_norm - gain_at(map.normalized, high_min, map.origin)))
            maximum = gain_db(map.normalized, minimum_norm + strength,
                0, -map.origin, endpoint_precision, map.origin)
            if stored.maximum <= -map.origin and math.abs(strength - (gain_at(map.normalized, stored.maximum, map.origin)
                - gain_at(map.normalized, minimum, map.origin))) <= endpoint_precision then
                maximum = stored.maximum
            end
        else
            local _, csv = r.GetSetMediaTrackInfo_String(track, legacy_map_key, '', false)
            local legacy = decode_curve(csv or '', 31)
            if legacy then maximum = gain_db(legacy, legacy[1] + strength, 0, 3, strength_precision, 0) end
        end
        return model.validate({ frequency = frequency, minimum = minimum, maximum = maximum,
            threshold = config(fx, param, 'acs.dblo'), ceiling = config(fx, param, 'acs.dbhi'),
            attack = config(fx, param, 'acs.attack'), release = config(fx, param, 'acs.release') })
    end
    function session.read()
        local ok, result = pcall(native_read)
        if ok then return result end
        return nil, tostring(result)
    end
    function session.begin()
        if transaction then return true end
        assert(r.EnumProjects(-1, '') == project, 'Switch back to the brightness project before editing.')
        local settings = native_read()
        local fx, param = identity()
        safety(fx, param)
        if not curve() then
            model.apply(r, project, track, settings)
            fx, param = identity()
            assert(curve(), 'Gain calibration is missing. Reapply the brightness EQ setup.')
            settings = native_read()
        end
        local captured, chunk = r.GetTrackStateChunk(track, '', false)
        assert(captured, 'Could not capture the brightness track for rollback.')
        r.Undo_BeginBlock2(project)
        transaction = { chunk = chunk, settings = settings, dirty = false }
        return true
    end
    local function rollback(message)
        local current = transaction
        transaction = nil
        if current then
            local valid = pcall(identity)
            if valid then
                if not r.SetTrackStateChunk(track, current.chunk, false) then
                    message = message .. '\nRollback failed; use Undo to restore the track.'
                end
            end
            if project_open() then
                r.Undo_EndBlock2(project, 'GPhil: Live brightness change failed', -1)
                r.UpdateArrange()
            end
        end
        error(message, 0)
    end
    function session.update(settings)
        local ok, err = pcall(function()
            model.validate(settings)
            session.begin()
            assert(r.EnumProjects(-1, '') == project, 'The active project changed during brightness editing.')
            local fx, param = identity()
            safety(fx, param)
            local previous = transaction.settings
            if settings.frequency ~= previous.frequency then
                assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 0, settings.frequency, false),
                    'Could not update shelf frequency.')
            end
            local baseline, strength = M.mapping(r, track, settings.minimum, settings.maximum)
            if settings.minimum ~= previous.minimum then
                assert(r.TrackFX_SetNamedConfigParm(track, fx, 'param.' .. param .. '.mod.baseline', tostring(baseline)),
                    'Could not update native brightness minimum.')
            end
            if settings.minimum ~= previous.minimum or settings.maximum ~= previous.maximum then
                assert(r.TrackFX_SetNamedConfigParm(track, fx, 'param.' .. param .. '.acs.strength', tostring(strength)),
                    'Could not update native brightness range.')
            end
            local values = { threshold = { 'acs.dblo', settings.threshold }, ceiling = { 'acs.dbhi', settings.ceiling },
                attack = { 'acs.attack', settings.attack }, release = { 'acs.release', settings.release } }
            for key, entry in pairs(values) do
                if settings[key] ~= previous[key] then
                    assert(r.TrackFX_SetNamedConfigParm(track, fx, 'param.' .. param .. '.' .. entry[1], tostring(entry[2])),
                        'Could not update native brightness ' .. key .. '.')
                end
            end
            if model.encode(settings) ~= model.encode(previous) then transaction.dirty = true end
            transaction.settings = assert(model.decode(model.encode(settings)))
        end)
        if not ok then rollback(tostring(err)) end
        return true
    end
    function session.finish()
        if not transaction then return true end
        if not project_open() then transaction = nil; return true end
        local ok, err = pcall(function()
            identity()
            if transaction.dirty then
                local csv = model.encode(model.validate(transaction.settings))
                assert(r.GetSetMediaTrackInfo_String(track, settings_key, csv, true), 'Could not save brightness settings.')
                r.SetExtState('GPhil_DynamicBrightness', 'last_settings_v1', csv, true)
            end
        end)
        if not ok then rollback(tostring(err)) end
        transaction = nil
        r.Undo_EndBlock2(project, 'GPhil: Adjust dynamic brightness', -1)
        r.UpdateArrange()
        return true
    end
    function session.close() return session.finish() end
    return session
end

return M
