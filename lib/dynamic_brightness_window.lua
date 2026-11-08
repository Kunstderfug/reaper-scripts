-- GPhil GFX view. Audio processing and persistent presets live in separate modules.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local model = dofile(here .. 'dynamic_brightness.lua')
local live = dofile(here .. 'dynamic_brightness_live.lua')
local presets = dofile(here .. 'dynamic_brightness_presets.lua')
local widgets = dofile(here .. 'cc_widgets.lua')
local pins = dofile(here .. 'cc_pin.lua')
local rows = {
    { 'frequency', 'Shelf frequency', 'Hz', 1000, 16000, 10, true },
    { 'maximum', 'Boost limit', 'dB', 0, 12, .1 },
    { 'minimum', 'Cut limit', 'dB', -12, 0, .1 },
    { 'threshold', 'Full cut at', 'dBFS', -90, -1, .5 },
    { 'ceiling', 'Full boost at', 'dBFS', -89, 0, .5 },
    { 'attack', 'Attack', 'ms', 0, 1000, 5 },
    { 'release', 'Release', 'ms', 0, 1000, 5 },
}
local function number(value)
    return string.format('%.6f', value):gsub('0+$', ''):gsub('%.$', '')
end
local function error_line(err)
    return tostring(err):match('^[^\n]+'):gsub('^.-:%d+: ', '')
end
local function edit(text, key, replace, numeric)
    if key == 1 then return text, true end
    if key == 8 or key == 127 then
        local cut = utf8.offset(text, -1)
        return replace and '' or cut and text:sub(1, cut - 1) or '', false
    end
    if key >= 32 and key <= 0x10ffff and key ~= 127 then
        local char = utf8.char(key)
        if not numeric or char:match('[%d%.%-]') then
            local candidate = (replace and '' or text) .. char
            return #candidate <= (numeric and 16 or 60) and candidate or text, false
        end
    end
    return text, replace
end

function M.open(api, g)
    local project = api.EnumProjects(-1, '')
    local track = model.target(api, project)
    local store = presets.new(api, model)
    local ui = widgets.new(g)
    local session = live.new(api, model, project, track)
    local s = { preset = 'Custom', status = 'Sliders update the EQ live. Enter commits a typed value.' }
    local function set_fields(settings)
        s.text = {}
        for _, row in ipairs(rows) do s.text[row[1]] = number(settings[row[1]]) end
        s.focus, s.drag, s.dirty = nil, nil, false
    end
    local function values()
        local settings = {}
        for _, row in ipairs(rows) do settings[row[1]] = tonumber(s.text[row[1]]) end
        return model.validate(settings)
    end
    local function valid_target()
        return api.EnumProjects(-1, '') == project and api.ValidatePtr2(project, track, 'MediaTrack*')
    end
    local function refresh_fx()
        s.fx = model.find(api, track)
        s.param = s.fx and model.gain_parameter(api, track, s.fx) or nil
    end
    local function apply(settings, preset)
        local ok, result = pcall(function()
            assert(valid_target(), 'Return to the original project to edit this EQ.')
            local parsed = settings or values()
            if model.find(api, track) then
                session.begin(); session.update(parsed); session.finish()
            else model.apply(api, project, track, parsed) end
            refresh_fx()
            set_fields(parsed)
            s.native = model.encode(parsed)
            return { fx = s.fx, param = s.param }
        end)
        s.error = not ok
        if ok then
            s.fx, s.param = result.fx, result.param
            s.preset = preset or 'Custom'
            s.status = 'Applied. These settings will also be the starting point in new projects.'
        else s.status = error_line(result) end
        return ok
    end
    set_fields(model.settings(api, track))
    refresh_fx()
    if not s.fx then apply() end
    local native, issue = session.read()
    if native then set_fields(native); s.native = model.encode(native)
    elseif issue then s.status, s.error = issue, true end
    local pin = pins.open(api, g, 'GPhil | Dynamic brightness', 660, 530)
    api.atexit(function() pcall(session.close); g.quit() end)

    local function preview()
        local ok, err = pcall(function()
            assert(valid_target(), 'Return to the original project to edit this EQ.')
            session.update(values())
        end)
        s.error = not ok
        if not ok then
            pcall(session.close); s.drag = nil; s.status = error_line(err)
        else s.status = 'Updating ReaEQ live. Release to remember these settings.' end
    end

    local function choose_preset()
        local entries, labels = store.list(), {}
        for _, entry in ipairs(entries) do
            local name = entry.name:gsub('[|<>!#&]', ' ')
            labels[#labels + 1] = (entry.name == s.preset and '!' or '') .. name
        end
        g.x, g.y = 20 * ui.scale, 429 * ui.scale
        local index = g.showmenu(table.concat(labels, '|'))
        if entries[index] then apply(entries[index].settings, entries[index].name) end
    end
    local function save_preset()
        local ok, name = pcall(function() return store.save(s.name, values()) end)
        s.error = not ok
        if ok then
            s.preset, s.saving = name, false
            s.status = 'Saved preset: ' .. name
        else s.status = error_line(name) end
    end
    local function preset_name(key, click)
        ui.rect(12, 388, 636, 114, 'panel')
        ui.text(24, 399, 'SAVE PRESET AS', 11, 'muted')
        if key == 27 then s.saving = false
        elseif key == 13 then save_preset()
        else s.name, s.replace = edit(s.name, key, s.replace, false) end
        ui.rect(24, 421, 354, 32, 'active')
        -- Clip long names rather than allowing text to overlap buttons.
        ui.color('text'); g.setfont(1, 'Arial', math.floor(15 * ui.scale))
        g.x, g.y = 34 * ui.scale, 428 * ui.scale
        g.drawstr(s.name .. '|', 0, 368 * ui.scale, 452 * ui.scale)
        ui.click = click
        if ui.button(390, 421, 116, 32, 'Save', false, true, true) then save_preset() end
        if ui.button(518, 421, 116, 32, 'Cancel') then s.saving = false end
        ui.text(24, 467, 'Using an existing name replaces that user preset.', 12, 'muted')
    end
    local function draw(key, available)
        ui.begin()
        local click = ui.click
        if s.saving or not available then ui.click = false end
        ui.text(20, 12, 'GPHIL / AUDIO TOOLS', 10, 'accent')
        ui.text(20, 29, 'Dynamic brightness', 25)
        if ui.button(431, 28, 111, 26, 'Open ReaEQ', false, s.fx ~= nil) then
            refresh_fx()
            if s.fx then api.TrackFX_Show(track, s.fx, 3) end -- Float only this FX.
        end
        if ui.button(554, 28, 86, 26, pin.enabled and 'Pinned' or 'Pin', pin.enabled, pin.window ~= nil) then
            pin.set(not pin.enabled)
        end
        local name = ''
        if available then local ignored; ignored, name = api.GetTrackName(track, '') end
        ui.text(20, 66, available and ('Track: ' .. name .. '  /  less treble when soft, more when loud')
            or 'Return to the original project to use these controls.', 13, 'muted')
        ui.rect(20, 90, 620, 1, 'line')
        local enabled = available and s.fx and api.TrackFX_GetEnabled(track, s.fx)
        if ui.button(20, 101, 120, 30, enabled and 'Enabled' or 'Bypassed', enabled, s.fx ~= nil) then
            refresh_fx()
            if s.fx then
                api.Undo_BeginBlock2(project)
                api.TrackFX_SetEnabled(track, s.fx, not api.TrackFX_GetEnabled(track, s.fx))
                api.Undo_EndBlock2(project, 'GPhil: Toggle dynamic brightness', -1)
            end
        end
        local delta, delta_supported = false, false
        if available then delta, delta_supported = model.delta(api, track) end
        if ui.button(150, 101, 120, 30, delta and 'Delta: ON' or 'Delta', delta, delta_supported and (enabled or delta)) then
            local ok, err = pcall(model.set_delta, api, project, track, not delta)
            s.error = not ok
            s.status = ok and (delta and 'Full processed output.' or 'Delta: EQ difference. Other tracks can still play; solo BUS to isolate it.')
                or error_line(err)
        end
        local boost = 0
        if available and s.fx then
            local _, formatted = api.TrackFX_GetFormattedParamValue(track, s.fx, s.param, '')
            boost = tonumber(formatted:match('([%+%-]?[%d%.]+)')) or 0
        end
        ui.text(285, 109, 'Live ' .. string.format('%+.1f dB', enabled and boost or 0), 14,
            enabled and 'teal' or 'muted')
        ui.rect(426, 111, 214, 10, 'panel')
        local meter = math.max(-1, math.min(1, enabled and boost / 12 or 0))
        ui.rect(meter < 0 and 533 + 107 * meter or 533, 111, 107 * math.abs(meter), 10,
            meter < 0 and 'teal' or 'accent')
        ui.rect(532, 108, 2, 16, 'muted')
        ui.rect(20, 146, 620, 1, 'line')
        for i, row in ipairs(rows) do
            local field, label, unit, low, high, step, logarithmic = table.unpack(row)
            local y = 159 + (i - 1) * 32
            ui.text(20, y + 7, label, 14)
            if ui.click then
                if ui.hit(496, y, 144, 30) then s.focus, s.replace = field, true
                elseif ui.hit(188, y, 288, 30) then s.focus, s.drag, s.snapped = nil, field, false
                elseif s.focus == field then s.focus = nil end
            end
            if s.focus == field and not s.saving then
                if key == 13 then apply()
                elseif key == 27 then
                    local current = session.read() or model.settings(api, track)
                    s.text[field], s.focus, s.dirty = number(current[field]), nil, false
                    for _, candidate in ipairs(rows) do
                        local value = tonumber(s.text[candidate[1]])
                        if not value or math.abs(value - current[candidate[1]]) > .000001 then s.dirty = true end
                    end
                else
                    local before = s.text[field]
                    s.text[field], s.replace = edit(before, key, s.replace, true)
                    if before ~= s.text[field] then s.preset, s.dirty = 'Custom', true end
                end
            end
            if s.drag == field and available then
                local fraction = math.max(0, math.min(1, (g.mouse_x / ui.scale - 188) / 288))
                local value = logarithmic and low * (high / low) ^ fraction or low + (high - low) * fraction
                value = math.max(low, math.min(high, math.floor(value / step + .5) * step))
                local default = model.defaults[field]
                local default_fraction = logarithmic and math.log(default / low) / math.log(high / low)
                    or (default - low) / (high - low)
                s.snapped = math.abs(fraction - default_fraction) * 288 < (s.snapped and 10 or 6)
                if s.snapped then value = default end
                if field == 'threshold' then
                    local ceiling = tonumber(s.text.ceiling) or 0
                    value = math.min(value, ceiling - math.min(.5, (ceiling - low) / 2))
                end
                if field == 'ceiling' then
                    local threshold = tonumber(s.text.threshold) or -90
                    value = math.max(value, threshold + math.min(.5, (high - threshold) / 2))
                end
                local changed = tonumber(s.text[field]) ~= value
                s.text[field], s.preset = number(value), 'Custom'
                if changed then s.dirty = true; preview() end
            end
            local value = math.max(low, math.min(high, tonumber(s.text[field]) or low))
            local fraction = logarithmic and math.log(value / low) / math.log(high / low) or (value - low) / (high - low)
            ui.rect(188, y + 13, 288, 4, 'line')
            local default = model.defaults[field]
            local mark = logarithmic and math.log(default / low) / math.log(high / low) or (default - low) / (high - low)
            ui.rect(188 + 288 * mark - 1, y + 7, 2, 16, 'muted')
            ui.rect(188, y + 13, 288 * fraction, 4, 'accent')
            ui.rect(188 + 282 * fraction, y + 7, 6, 16, s.drag == field and 'teal' or 'accent')
            ui.rect(496, y, 144, 30, s.focus == field and 'active' or 'panel')
            ui.text(508, y + 6, s.text[field] .. (s.focus == field and '|' or ''), 15)
            ui.text(593, y + 8, unit, 11, 'muted')
        end
        if s.drag and g.mouse_cap & 1 == 0 then
            s.drag = nil
            local ok, err = pcall(session.finish)
            s.error = not ok
            s.status = ok and 'Applied. Last-used settings remembered for new projects.' or error_line(err)
            if ok then s.native, s.dirty = model.encode(values()), false end
        end
        if ui.button(20, 399, 288, 30, 'Preset: ' .. s.preset) then choose_preset() end
        if ui.button(320, 399, 150, 30, 'Save preset…') and apply(nil, s.preset) then
            s.saving, s.name, s.replace = true, s.preset == 'Custom' and '' or s.preset, true
        end
        local user_preset = false
        for _, entry in ipairs(store.list()) do
            if entry.name == s.preset then user_preset = not entry.builtin end
        end
        if ui.button(482, 399, 158, 30, 'Delete preset', false, user_preset) then
            store.delete(s.preset); s.preset = 'Custom'; s.status = 'User preset deleted.'
        end
        ui.wrap(20, 445, s.error and s.status or available and s.status
            or 'Project changed or target track removed. Reopen this script for a different track.',
            408, 12, s.error and 'error' or 'muted', 3)
        if ui.button(450, 452, 190, 38, s.fx and 'Apply settings' or 'Create EQ', false, true, true) then apply() end
        ui.text(20, 510, delta and (enabled
            and 'DELTA: difference from this EQ. Other tracks may still reach the master.'
            or 'Delta is armed, but the EQ is bypassed. Enable the EQ to audition its difference.')
            or 'Shelf moves from Cut limit at the lower input level to Boost limit at the upper level.', 10, delta and 'teal' or 'muted')
        if s.saving then preset_name(key, click) end
    end
    local function frame()
        local ok, err = xpcall(function()
            local key = g.getchar()
            if key < 0 or key == 27 and not s.focus and not s.saving then g.quit(); return end
            local available = valid_target()
            if available and api.time_precise() >= (s.check_at or 0) then
                refresh_fx(); s.check_at = api.time_precise() + .2
            end
            if not available then
                if s.drag then pcall(session.close) end
                s.drag, s.focus = nil, nil
            elseif not s.drag and not s.focus and not s.saving and not s.dirty and api.time_precise() >= (s.sync_at or 0) then
                local current, issue = session.read()
                if current and model.encode(current) ~= s.native then
                    set_fields(current); s.native = model.encode(current); s.preset = 'Custom'
                    s.status, s.error = 'Synced with ReaEQ.', false
                elseif issue then s.status, s.error = issue, true end
                s.sync_at = api.time_precise() + .2
            end
            draw(key, available)
            g.update(); pin.update(); api.defer(frame)
        end, debug.traceback)
        if not ok then g.quit(); api.ShowMessageBox(tostring(err), 'Dynamic brightness', 0) end
    end
    frame()
end
return M
