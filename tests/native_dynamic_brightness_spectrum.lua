-- Run only in the CURRENT REAPER app. Isolated silent tab, restored afterward.
-- Measures the native shelf and Delta across the spectrum; no cutoff assumption.
local r = reaper
if not r then print('SKIP: requires native REAPER'); return end
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])tests[/\\]'))
local model = dofile(root .. 'lib/dynamic_brightness.lua')
local directory = '/tmp/gphil-dynamic-brightness-spectrum/'
r.RecursiveCreateDirectory(directory, 0)
local report = assert(io.open(directory .. 'report.txt', 'w'))
local function log(s) report:write(s .. '\n'); report:flush() end
local original = r.EnumProjects(-1, '')
local section, key = 'GPhil_DynamicBrightness', 'last_settings_v1'
local had_last = r.HasExtState(section, key)
local last = r.GetExtState(section, key)
local project
local ok, err = xpcall(function()
    local frequencies = { 63, 125, 250, 500, 1000, 2000, 4000, 8000, 12000 }
    local rate, duration, level = 48000, 2, -6
    local samples, amplitude = {}, 32767 * 10 ^ (level / 20)
    for _, hz in ipairs(frequencies) do
        for i = 0, rate * duration - 1 do
            local value = math.floor(amplitude * math.sin(2 * math.pi * hz * i / rate))
            samples[#samples + 1] = string.pack('<i2i2', value, value)
        end
    end
    local data = table.concat(samples)
    local wave = assert(io.open(directory .. 'input.wav', 'wb'))
    wave:write('RIFF', string.pack('<I4', #data + 36), 'WAVEfmt ',
        string.pack('<I4I2I2I4I4I2I2', 16, 1, 2, rate, rate * 4, 4, 16),
        'data', string.pack('<I4', #data), data)
    wave:close()
    r.Main_OnCommand(40859, 0) -- new project tab in this running instance
    project = r.EnumProjects(-1, '')
    assert(project ~= original and r.CountTracks(project) == 0)
    local master = r.GetMasterTrack(project)
    for i = r.GetTrackNumSends(master, 1) - 1, 0, -1 do r.RemoveTrackSend(master, 1, i) end
    r.SetMediaTrackInfo_Value(master, 'D_VOL', 1)
    r.InsertTrackAtIndex(0, false)
    local track = r.GetTrack(project, 0)
    r.GetSetMediaTrackInfo_String(track, 'P_NAME', 'BUS', true)
    r.SetMediaTrackInfo_Value(track, 'D_VOL', 1)
    r.SetMediaTrackInfo_Value(track, 'D_PAN', 0)
    local settings = assert(model.decode(model.encode(model.defaults)))
    settings.frequency, settings.maximum, settings.minimum = 2000, 3, 0
    settings.threshold, settings.ceiling = -30, -12
    settings.attack, settings.release = 50, 300
    local result = model.apply(r, project, track, settings)
    log('Settings: ' .. model.encode(settings))
    log('Tones: 63,125,250,500,1000,2000,4000,8000,12000 Hz; 2 s each; -6 dBFS peak')
    for p = 0, r.TrackFX_GetNumParams(track, result.fx) - 1 do
        local _, name = r.TrackFX_GetParamName(track, result.fx, p, '')
        local _, formatted = r.TrackFX_GetFormattedParamValue(track, result.fx, p, '')
        log(('Parameter %d %s = %s'):format(p, name, formatted))
    end
    local item = r.AddMediaItemToTrack(track)
    local take = r.AddTakeToMediaItem(item)
    r.SetMediaItemTake_Source(take, r.PCM_Source_CreateFromFile(directory .. 'input.wav'))
    local length = duration * #frequencies
    r.SetMediaItemInfo_Value(item, 'D_LENGTH', length)
    for option, value in pairs({ RENDER_SETTINGS = 0, RENDER_BOUNDSFLAG = 0,
        RENDER_STARTPOS = 0, RENDER_ENDPOS = length, RENDER_CHANNELS = 2,
        RENDER_SRATE = rate, RENDER_ADDTOPROJ = 0, RENDER_TAILFLAG = 0,
        RENDER_NORMALIZE = 0, RENDER_DITHER = 0 }) do
        r.GetSetProjectInfo(project, option, value, true)
    end
    r.GetSetProjectInfo_String(project, 'RENDER_FILE', directory, true)
    r.GetSetProjectInfo_String(project, 'RENDER_FORMAT', 'ZXZhdxgAAA==', true)
    r.GetSetProjectInfo_String(project, 'RENDER_FORMAT2', '', true)
    local function render(name)
        r.GetSetProjectInfo_String(project, 'RENDER_PATTERN', name, true)
        os.remove(directory .. name .. '.wav') -- only outputs of this isolated fixture
        local success, stats = r.GetSetProjectInfo_String(project, 'RENDER_STATS', '42230', false)
        assert(success and r.file_exists(directory .. name .. '.wav'), 'Missing ' .. name .. ' render')
        log(name .. ': ' .. stats)
    end
    render('dynamic')
    model.set_delta(r, project, track, true)
    assert(model.delta(r, track))
    render('delta')
    model.set_delta(r, project, track, false)
    r.TrackFX_SetEnabled(track, result.fx, false)
    render('unity')
    log('PASS: native spectrum renders complete; analyze with dynamic_brightness_spectrum.py')
end, debug.traceback)
if not ok then log('FAIL: ' .. tostring(err)) end
if had_last then r.SetExtState(section, key, last, true)
else r.DeleteExtState(section, key, true) end
if project then
    r.SelectProjectInstance(project)
    r.Main_SaveProjectEx(project, directory .. 'fixture.rpp', 8)
    r.Main_OnCommand(40860, 0) -- close the saved isolated tab
end
r.SelectProjectInstance(original)
report:close()
if not ok then r.ShowMessageBox(tostring(err), 'Dynamic brightness spectrum test', 0) end
