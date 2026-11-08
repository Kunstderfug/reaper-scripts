-- Configuration only. REAPER's audio follower runs during playback/render.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
M.defaults = { frequency = 2000, maximum = 3, threshold = -30, ceiling = -12,
    attack = 50, release = 300, minimum = -3 }
local owner_key = 'P_EXT:GPhil_dynamicBrightnessFX'
local settings_key = 'P_EXT:GPhil_dynamicBrightnessSettings'
local fields = { 'frequency', 'maximum', 'threshold', 'ceiling', 'attack', 'release', 'minimum' }

function M.validate(s)
    if s.minimum == nil then s.minimum = 0 end -- Legacy six-setting callers.
    for _, key in ipairs(fields) do
        assert(type(s[key]) == 'number' and s[key] == s[key], 'Enter a number for ' .. key .. '.')
    end
    assert(s.frequency >= 1000 and s.frequency <= 16000, 'Shelf frequency must be 1000–16000 Hz.')
    assert(s.maximum >= 0 and s.maximum <= 12, 'Maximum boost must be 0–12 dB.')
    assert(s.minimum >= -12 and s.minimum <= 0, 'Cut limit must be -12–0 dB.')
    assert(s.threshold >= -90 and s.threshold < s.ceiling and s.ceiling <= 0,
        'Full-cut/full-boost levels must satisfy -90 <= cut < boost <= 0 dBFS.')
    assert(s.attack >= 0 and s.attack <= 1000 and s.release >= 0 and s.release <= 1000,
        'Attack and release must be 0–1000 ms.')
    return s
end

function M.encode(s)
    local values = {}
    for _, key in ipairs(fields) do values[#values + 1] = tostring(key == 'minimum' and (s[key] or 0) or s[key]) end
    return table.concat(values, ',')
end

function M.decode(csv)
    local s, i = {}, 0
    for part in (csv .. ','):gmatch('(.-),') do
        i = i + 1
        if not fields[i] then return nil end
        s[fields[i]] = tonumber(part)
    end
    if i == 6 then s.minimum = 0 end -- Existing projects and presets stay boost-only.
    if (i ~= 6 and i ~= #fields) or not pcall(M.validate, s) then return nil end
    return s
end

function M.target(r, project)
    local buses = {}
    for i = 0, r.CountTracks(project) - 1 do
        local tr = r.GetTrack(project, i)
        local _, name = r.GetTrackName(tr, '')
        if name:match('^%s*(.-)%s*$'):upper() == 'BUS' then buses[#buses + 1] = tr end
    end
    assert(#buses <= 1, 'More than one track is named BUS. Give the target a unique name.')
    if #buses == 1 then return buses[1] end
    assert(r.CountSelectedTracks(project) == 1, 'Select one track, or name the target track BUS.')
    return r.GetSelectedTrack(project, 0)
end

function M.settings(r, track)
    local _, csv = r.GetSetMediaTrackInfo_String(track, settings_key, '', false)
    local last = r.GetExtState('GPhil_DynamicBrightness', 'last_settings_v1')
    return M.decode(csv) or M.decode(last) or M.decode(M.encode(M.defaults))
end

function M.find(r, track)
    local _, guid = r.GetSetMediaTrackInfo_String(track, owner_key, '', false)
    if guid == '' then return nil end
    local function visit(fx)
        if r.TrackFX_GetFXGUID(track, fx) == guid then return fx end
        local container, count = r.TrackFX_GetNamedConfigParm(track, fx, 'container_count')
        if container then
            for i = 0, tonumber(count) - 1 do
                local found, child = r.TrackFX_GetNamedConfigParm(track, fx, 'container_item.' .. i)
                if found then
                    local owned = visit(tonumber(child))
                    if owned then return owned end
                end
            end
        end
    end
    for fx = 0, r.TrackFX_GetCount(track) - 1 do
        local owned = visit(fx)
        if owned then return owned end
    end
end

local function shelf_gain(r, track, fx)
    for param = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
        local eq, band, index, kind = r.TrackFX_GetEQParam(track, fx, param)
        if eq and band == 4 and index == 0 and kind == 1 then return param end
    end
    error('The owned EQ has no high shelf. Restore its factory bands or remove it and rerun.')
end
M.gain_parameter = shelf_gain

function M.delta(r, track)
    local fx = M.find(r, track)
    local param = fx and r.TrackFX_GetParamFromIdent(track, fx, ':delta') or -1
    if param < 0 then return false, false end
    return r.TrackFX_GetParam(track, fx, param) >= .5, true
end

function M.set_delta(r, project, track, enabled)
    local fx = assert(M.find(r, track), 'The brightness EQ was removed. Create it again first.')
    local param = r.TrackFX_GetParamFromIdent(track, fx, ':delta')
    assert(param >= 0, 'This REAPER version does not expose Delta audition.')
    assert(not r.GetFXEnvelope(track, fx, param, false), 'Remove Delta automation before auditioning.')
    r.Undo_BeginBlock2(project)
    local ok = r.TrackFX_SetParamNormalized(track, fx, param, enabled and 1 or 0)
    r.Undo_EndBlock2(project, 'GPhil: Toggle dynamic brightness Delta', -1)
    assert(ok, 'Could not switch Delta audition.')
end

function M.apply(r, project, track, settings)
    local s = M.validate(settings)
    assert(r.GetPlayStateEx(project) & 4 == 0, 'Stop recording before configuring the EQ.')
    local fx = M.find(r, track)
    local enabled = fx == nil or r.TrackFX_GetEnabled(track, fx)
    if fx then
        local param = shelf_gain(r, track, fx)
        for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
            assert(not r.GetFXEnvelope(track, fx, p, false),
                'The brightness EQ has an automation envelope. Remove that envelope before rerunning setup.')
            local has_mod, active = r.TrackFX_GetNamedConfigParm(track, fx, 'param.' .. p .. '.mod.active')
            assert(p == param or not has_mod or tonumber(active) ~= 1,
                'The brightness EQ has extra parameter modulation. Remove it before rerunning setup.')
        end
    end
    local captured, before = r.GetTrackStateChunk(track, '', false)
    assert(captured, 'Could not capture the target track for rollback.')
    r.Undo_BeginBlock2(project)
    r.PreventUIRefresh(1)
    local ok, result = xpcall(function()
        local created = fx == nil
        if created then
            fx = r.TrackFX_AddByName(track, 'ReaEQ (Cockos)', false, -1)
            assert(fx >= 0, 'Could not load ReaEQ (Cockos).')
            assert(r.TrackFX_SetPresetByIndex(track, fx, -2), 'Could not load ReaEQ factory defaults.')
        end
        local param = shelf_gain(r, track, fx)
        local function config(key, value)
            assert(r.TrackFX_SetNamedConfigParm(track, fx, key, tostring(value)), 'Cannot set ' .. key)
        end
        local prefix = 'param.' .. param .. '.'
        config(prefix .. 'mod.active', 0)
        config(prefix .. 'lfo.active', 0)
        config(prefix .. 'plink.active', 0)
        -- SetEQParam accepts linear amplitude for gain when isnorm=false.
        -- ReaEQ baseline uses the raw VST scale (unity=0.25), but ACS strength
        -- uses its specialized normalized automation taper (unity=0.5).
        assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 1, 1, false))
        local raw_zero, minimum, maximum = r.TrackFX_GetParam(track, fx, param)
        local zero = (raw_zero - minimum) / (maximum - minimum)
        local norm_zero = r.TrackFX_GetParamNormalized(track, fx, param)
        assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 1, 10 ^ (s.maximum / 20), false))
        local top = r.TrackFX_GetParamNormalized(track, fx, param)
        assert(top >= norm_zero and top <= 1 and zero >= 0, 'Unexpected ReaEQ gain mapping.')
        assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 1, 1, false))
        -- Cache the installed plug-in's native gain taper for later live edits.
        local live = dofile(here .. 'dynamic_brightness_live.lua')
        live.calibrate(r, track, fx, param)
        local baseline, strength = live.mapping(r, track, s.minimum, s.maximum)
        assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 1, 10 ^ (s.minimum / 20), false))
        for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
            local eq, band, index, kind = r.TrackFX_GetEQParam(track, fx, p)
            if eq and kind == 0 then
                assert(r.TrackFX_SetEQBandEnabled(track, fx, band, index, band == 4 and index == 0))
            end
        end
        assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 0, s.frequency, false))
        assert(r.TrackFX_SetEQParam(track, fx, 4, 0, 2, 1, false))
        for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
            local _, name = r.TrackFX_GetParamName(track, fx, p, '')
            -- Master gain's native parameter is amplitude 0..4. Use it
            -- directly; the specialized EQ setter has a different mapping.
            if name == 'Global Gain' and math.abs(r.TrackFX_GetParam(track, fx, p) - 1) > 1e-9 then
                assert(r.TrackFX_SetParam(track, fx, p, 1))
            end
            if name == 'Wet' and math.abs(r.TrackFX_GetParamNormalized(track, fx, p) - 1) > 1e-9 then
                assert(r.TrackFX_SetParamNormalized(track, fx, p, 1))
            end
            -- Delta is an audition state. Leave it untouched during setup.
        end
        for key, value in pairs({ ['mod.baseline'] = baseline, ['acs.strength'] = strength,
            ['acs.dir'] = 1, ['acs.attack'] = s.attack, ['acs.release'] = s.release,
            ['acs.dblo'] = s.threshold, ['acs.dbhi'] = s.ceiling,
            ['acs.chan'] = 0, ['acs.stereo'] = 1, ['acs.x2'] = 0.5, ['acs.y2'] = 0.5,
            ['acs.active'] = 1 }) do config(prefix .. key, value) end
        config(prefix .. 'mod.active', 1)
        config('renamed_name', 'Dynamic brightness')
        r.TrackFX_SetEnabled(track, fx, enabled)
        if not created then
            -- REAPER can retain an inactive audio-control input after rebuilding
            -- an existing modulation block. Restart this EQ for full setup only;
            -- ordinary GFX gestures use the live path and never restart it.
            r.TrackFX_SetOffline(track, fx, true)
            r.TrackFX_SetOffline(track, fx, false)
            assert(not r.TrackFX_GetOffline(track, fx), 'Could not restart the brightness EQ.')
        end
        r.GetSetMediaTrackInfo_String(track, owner_key, r.TrackFX_GetFXGUID(track, fx), true)
        r.GetSetMediaTrackInfo_String(track, settings_key, M.encode(s), true)
        return { fx = fx, param = param, zero = zero, top = top, baseline = baseline, created = created }
    end, debug.traceback)
    if not ok then
        local restored = r.SetTrackStateChunk(track, before, false)
        if not restored then result = tostring(result) .. '\nRollback failed; use Undo to restore the track.' end
    end
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock2(project, ok and 'GPhil: Configure dynamic brightness (-12–12 dB)'
        or 'GPhil: Dynamic brightness setup failed', -1)
    r.UpdateArrange()
    if not ok then error(result, 0) end
    r.SetExtState('GPhil_DynamicBrightness', 'last_settings_v1', M.encode(s), true)
    return result
end

return M
