-- Run in the CURRENT REAPER app. Uses a new, silent test tab and restores it.
-- Writes four WAV renders and a report to /tmp/gphil-dynamic-brightness-test/.
local r = reaper
if not r then print('SKIP: requires native REAPER'); return end
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local model = dofile(root .. 'lib/dynamic_brightness.lua')
local boost_only = model.decode(model.encode(model.defaults))
boost_only.minimum = 0
local directory = '/tmp/gphil-dynamic-brightness-test/'
r.RecursiveCreateDirectory(directory, 0)
local report = assert(io.open(directory .. 'report.txt', 'w'))
local function log(s) report:write(s .. '\n'); report:flush() end
local original = r.EnumProjects(-1, '')
local state_section, state_key = 'GPhil_DynamicBrightness', 'last_settings_v1'
local had_last_settings = r.HasExtState(state_section, state_key)
local original_last_settings = r.GetExtState(state_section, state_key)
local project
local function run()
local ok, err = xpcall(function()
    local frames, rate = {}, 48000
    for _, db in ipairs({ -60, -40, -30, -24, -18, -12, -6, -6, -60 }) do
        local amplitude = 32767 * 10 ^ (db / 20)
        for i = 0, rate * 2 - 1 do
            local sample = math.floor(amplitude * math.sin(2 * math.pi * 12000 * i / rate))
            frames[#frames + 1] = string.pack('<i2i2', sample, sample)
        end
    end
    local data = table.concat(frames)
    local wave = assert(io.open(directory .. 'input.wav', 'wb'))
    wave:write('RIFF', string.pack('<I4', #data + 36), 'WAVEfmt ',
        string.pack('<I4I2I2I4I4I2I2', 16, 1, 2, rate, rate * 4, 4, 16),
        'data', string.pack('<I4', #data), data)
    wave:close()
    r.Main_OnCommand(40859, 0)
    project = r.EnumProjects(-1, '')
    assert(r.CountTracks(project) == 0)
    local master = r.GetMasterTrack(project)
    for i = r.GetTrackNumSends(master, 1) - 1, 0, -1 do r.RemoveTrackSend(master, 1, i) end
    -- No hardware outputs in this test tab, even if transport is accidentally run.
    r.SetMediaTrackInfo_Value(master, 'D_VOL', 1)
    r.InsertTrackAtIndex(0, false)
    local track = r.GetTrack(project, 0)
    r.GetSetMediaTrackInfo_String(track, 'P_NAME', 'BUS', true)
    assert(model.target(r, project) == track)
    local original_fx = r.TrackFX_AddByName(track, 'ReaEQ (Cockos)', false, -1)
    r.TrackFX_SetEnabled(track, original_fx, false)
    local original_guid = r.TrackFX_GetFXGUID(track, original_fx)
    local first = model.apply(r, project, track, boost_only)
    local second = model.apply(r, project, track, boost_only)
    assert(r.TrackFX_GetCount(track) == 2 and first.fx == second.fx)
    assert(r.TrackFX_GetFXGUID(track, 0) == original_guid and not r.TrackFX_GetEnabled(track, 0))
    assert(math.abs(second.zero - 0.25) < 1e-6, 'Unexpected native ReaEQ baseline')
    log('PASS: native gain calibration, existing FX unchanged, rerun reuse')
    local enabled, supported = model.delta(r, track)
    assert(supported and not enabled, 'New EQ must expose Delta audition, initially off')
    model.set_delta(r, project, track, true)
    r.TrackFX_SetEnabled(track, second.fx, false)
    local changed = model.decode(model.encode(boost_only))
    changed.maximum = 2
    model.apply(r, project, track, changed)
    assert(model.delta(r, track) and not r.TrackFX_GetEnabled(track, second.fx),
        'Applying settings did not preserve Delta and bypass')
    assert(r.GetExtState(state_section, state_key) == model.encode(changed),
        'Successful setup did not persist last-used settings')
    model.apply(r, project, track, boost_only)
    assert(model.delta(r, track) and not r.TrackFX_GetEnabled(track, second.fx))
    model.set_delta(r, project, track, false)
    assert(not model.delta(r, track), 'Delta audition did not switch off')
    r.TrackFX_SetEnabled(track, second.fx, true)
    log('PASS: Delta toggle, apply preserves Delta/bypass, successful settings persist')
    -- REAPER canonicalizes default LANEREC/program-name metadata when reading
    -- chunks back. Compare actual FX parameters, ownership and modulation.
    local function snapshot()
        local values = { tostring(r.TrackFX_GetCount(track)), model.encode(model.settings(r, track)) }
        for fx = 0, r.TrackFX_GetCount(track) - 1 do
            values[#values + 1] = r.TrackFX_GetFXGUID(track, fx)
            values[#values + 1] = tostring(r.TrackFX_GetEnabled(track, fx))
            for p = 0, r.TrackFX_GetNumParams(track, fx) - 1 do
                values[#values + 1] = tostring(r.TrackFX_GetParam(track, fx, p))
            end
        end
        for _, key in ipairs({ 'mod.active', 'mod.baseline', 'acs.active', 'acs.strength',
            'acs.attack', 'acs.release', 'acs.dblo', 'acs.dbhi' }) do
            local _, value = r.TrackFX_GetNamedConfigParm(track, second.fx, 'param.' .. second.param .. '.' .. key)
            values[#values + 1] = value
        end
        return table.concat(values, '\n')
    end
    local before, writes = snapshot(), 0
    local last_before_failure = r.GetExtState(state_section, state_key)
    local broken = setmetatable({ TrackFX_SetNamedConfigParm = function(...)
        writes = writes + 1
        if writes == 2 then return false end
        return r.TrackFX_SetNamedConfigParm(...)
    end }, { __index = r })
    changed.maximum = 1
    assert(not pcall(model.apply, broken, project, track, changed))
    assert(before == snapshot(), 'Failed setup did not restore the track processing')
    assert(r.GetExtState(state_section, state_key) == last_before_failure,
        'Failed setup changed last-used settings')
    log('PASS: failed configuration rolls back native track chunk and preserves last-used settings')
    -- Refuse unrelated modulation that could defeat the bounded configuration.
    assert(r.TrackFX_SetNamedConfigParm(track, second.fx, 'param.15.mod.active', '1'))
    assert(not pcall(model.apply, r, project, track, boost_only))
    assert(r.TrackFX_SetNamedConfigParm(track, second.fx, 'param.15.mod.active', '0'))
    log('PASS: extra global gain modulation is rejected')
    local item = r.AddMediaItemToTrack(track)
    local take = r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take, r.PCM_Source_CreateFromFile(directory .. 'input.wav'))
    r.SetMediaItemInfo_Value(item, 'D_LENGTH', 18)
    for key, value in pairs({ RENDER_SETTINGS = 0, RENDER_BOUNDSFLAG = 0,
        RENDER_STARTPOS = 0, RENDER_ENDPOS = 18, RENDER_CHANNELS = 2,
        RENDER_SRATE = rate, RENDER_ADDTOPROJ = 0, RENDER_TAILFLAG = 0,
        RENDER_NORMALIZE = 0, RENDER_DITHER = 0 }) do
        r.GetSetProjectInfo(project, key, value, true)
    end
    r.GetSetProjectInfo_String(project, 'RENDER_FILE', directory, true)
    r.GetSetProjectInfo_String(project, 'RENDER_FORMAT', 'ZXZhdxgAAA==', true)
    r.GetSetProjectInfo_String(project, 'RENDER_FORMAT2', '', true)
    local function render(name)
        -- Let REAPER rebuild host modulation state after configuration changes.
        coroutine.yield()
        r.GetSetProjectInfo_String(project, 'RENDER_PATTERN', name, true)
        os.remove(directory .. name .. '.wav') -- only this test's generated output
        local success, stats = r.GetSetProjectInfo_String(project, 'RENDER_STATS', '42230', false)
        assert(success and r.file_exists(directory .. name .. '.wav'), 'Missing ' .. name .. ' render')
        log(name .. ': ' .. stats)
    end
    local fresh = model.decode(model.encode(boost_only)); fresh.minimum = -3
    model.apply(r, project, track, fresh)
    render('fresh_cut_boost')
    local fresh_live = dofile(root .. 'lib/dynamic_brightness_live.lua').new(r, model, project, track)
    fresh_live.begin(); fresh.minimum = -1.5; fresh_live.update(fresh); fresh_live.finish()
    render('fresh_live_cut15')
    model.apply(r, project, track, boost_only)
    render('dynamic')
    model.set_delta(r, project, track, true)
    assert(model.delta(r, track), 'Delta audition did not switch on')
    render('delta')
    model.set_delta(r, project, track, false)
    render('post_delta_restore')
    -- Host Wet and Delta use their normalized setters to preserve modulation.
    local wet = r.TrackFX_GetParamFromIdent(track, second.fx, ':wet')
    assert(wet >= 0)
    log('PASS: boost-only and Delta renders')
    local bipolar = model.decode(model.encode(boost_only))
    bipolar.minimum = -3
    local configured = model.apply(r, project, track, bipolar)
    local live = dofile(root .. 'lib/dynamic_brightness_live.lua').new(r, model, project, track)
    local native, problem = live.read(); assert(native, problem)
    assert(math.abs(native.minimum + 3) < .01 and math.abs(native.maximum - 3) < .01)
    render('cut_boost_initial')
    -- Check live lower-limit writes and restore the default before rendering.
    live.begin(); bipolar.minimum = -1.5; live.update(bipolar)
    native, problem = live.read(); assert(native, problem)
    assert(math.abs(native.minimum + 1.5) < .01)
    bipolar.minimum = -3; live.update(bipolar); live.finish()
    render('cut_boost')
    model.set_delta(r, project, track, true)
    render('cut_boost_delta')
    model.set_delta(r, project, track, false)
    log('PASS: bipolar native read/live edit and cut/boost/Delta renders')
    -- Leave headroom when testing the wider supported range.
    take = r.GetActiveTake(r.GetTrackMediaItem(track, 0))
    r.SetMediaItemTakeInfo_Value(take, 'D_VOL', .1)
    local wide = model.decode(model.encode(bipolar))
    wide.minimum, wide.maximum, wide.threshold, wide.ceiling = -12, 12, -60, -36
    model.apply(r, project, track, wide)
    local wide_read, problem = dofile(root .. 'lib/dynamic_brightness_live.lua').new(r, model, project, track).read()
    assert(wide_read, problem)
    assert(math.abs(wide_read.minimum + 12) < .01 and math.abs(wide_read.maximum - 12) < .01)
    render('wide')
    assert(r.TrackFX_SetNamedConfigParm(track, configured.fx, 'param.' .. configured.param .. '.mod.active', '0'))
    assert(r.TrackFX_SetEQParam(track, configured.fx, 4, 0, 1, 10 ^ (12 / 20), false))
    render('static12')
    assert(r.TrackFX_SetEQParam(track, configured.fx, 4, 0, 1, 10 ^ (-12 / 20), false))
    render('static_cut12')
    -- Reference-only operations come last: Wet=0 suspends host audio control.
    assert(r.TrackFX_SetParamNormalized(track, configured.fx, wet, 0))
    render('wide_unity')
    assert(r.TrackFX_SetParamNormalized(track, configured.fx, wet, 1))
    take = r.GetActiveTake(r.GetTrackMediaItem(track, 0))
    r.SetMediaItemTakeInfo_Value(take, 'D_VOL', 1)
    assert(r.TrackFX_SetEQParam(track, configured.fx, 4, 0, 1, 10 ^ (3 / 20), false))
    render('static3')
    assert(r.TrackFX_SetEQParam(track, configured.fx, 4, 0, 1, 10 ^ (-3 / 20), false))
    render('static_cut3')
    assert(r.TrackFX_SetParamNormalized(track, configured.fx, wet, 0))
    render('unity')
    log('PASS: supported -12/+12 endpoint read and audio renders; defaults remain -3/+3')
end, debug.traceback)
if not ok then log('FAIL: ' .. tostring(err)) end
-- apply() persists globally, so restore the user's preferences on success/failure.
if had_last_settings then
    r.SetExtState(state_section, state_key, original_last_settings, true)
else
    r.DeleteExtState(state_section, state_key, true)
end
if project then
    r.SelectProjectInstance(project)
    r.Main_SaveProjectEx(project, directory .. 'fixture.rpp', 8)
    r.Main_OnCommand(40860, 0) -- close this saved test tab
end
r.SelectProjectInstance(original)
report:close()
if not ok then r.ShowMessageBox(tostring(err), 'Dynamic brightness native test', 0) end

end
local worker = coroutine.create(run)
local function advance()
    local success, problem = coroutine.resume(worker)
    if not success then
        log('FAIL: ' .. tostring(problem))
        r.SelectProjectInstance(original)
        report:close()
        return
    end
    if coroutine.status(worker) ~= 'dead' then r.defer(advance) end
end
advance()
