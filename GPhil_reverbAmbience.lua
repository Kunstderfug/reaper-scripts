-- Run in any project with verb 1 / verb 2 (also accepts rev 1 / rev 2).
-- Creates/reuses mixer-only A/B/C buses and adds any missing output sends.
-- Existing levels, sends and active alternatives are preserved on rerun.
-- The difference control sets A/C symmetrically around zero, from 0 to 10 dB.
-- Save the project to retain routing, the difference, and the active alternative.
local r = reaper
local directory = debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])')
local model = dofile(directory .. 'lib/reverb_ambience.lua')
local ambience = model.new(r)
local project = r.EnumProjects(-1, '')
local ok, result = pcall(ambience.setup, project)
if not ok then
    r.ShowMessageBox(tostring(result), 'Reverb ambience', 0)
    return
end

gfx.init('Reverb ambience', 490, 315)
local held, pending_difference = false, nil
local function text(x, y, value)
    gfx.x, gfx.y = x, y
    gfx.drawstr(value)
end

local function db_label(db)
    if math.abs(db) < 0.0001 then return '0' end
    return (db > 0 and '+' or '') .. string.format('%.1f', db)
end

local function inside(x, y, width, height)
    return gfx.mouse_x >= x and gfx.mouse_x < x + width
        and gfx.mouse_y >= y and gfx.mouse_y < y + height
end

local function frame()
    local key = gfx.getchar()
    if key < 0 or key == 27 then gfx.quit(); return end
    gfx.set(0.10, 0.11, 0.13, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, true)
    gfx.setfont(1, 'Arial', 17)
    gfx.set(0.94, 0.94, 0.94, 1)
    local active = r.EnumProjects(-1, '') == project
    local valid, buses = false, nil
    if active then valid, buses = pcall(ambience.find, project) end
    local down = gfx.mouse_cap & 1 == 1
    text(18, 15, active and 'Choose the reverb amount' or 'Return to the original project tab')
    if active and valid and buses then
        local levels = ambience.levels(buses)
        local difference = pending_difference or ambience.difference(buses)
        for i, preset in ipairs(model.presets) do
            local x, y, width, height = 18 + (i - 1) * 156, 50, 144, 48
            local enabled = r.GetMediaTrackInfo_Value(buses[preset.id], 'B_MUTE') == 0
            if enabled then gfx.set(0.20, 0.55, 0.39, 1)
            else gfx.set(0.23, 0.25, 0.29, 1) end
            gfx.rect(x, y, width, height, true)
            gfx.set(1, 1, 1, 1)
            text(x + 14, y + 15, ({ 'A', 'B', 'C' })[i] .. ': '
                .. db_label(levels[preset.id]) .. ' dB')
            local clicked = down and not held and inside(x, y, width, height)
            if clicked or key == 48 + i then ambience.select(project, preset.id) end
        end
        gfx.set(0.94, 0.94, 0.94, 1)
        text(18, 115, string.format('Difference: %.1f dB  (A - / C +)', difference))
        local slider_x, slider_y, slider_width = 34, 157, 422
        if down and not held and inside(slider_x - 10, slider_y - 14, slider_width + 20, 28) then
            pending_difference = difference
        end
        if pending_difference ~= nil then
            if down then
                local fraction = math.max(0, math.min(1, (gfx.mouse_x - slider_x) / slider_width))
                pending_difference = math.floor(fraction * 20 + 0.5) / 2
                difference = pending_difference
            else
                ambience.set_difference(project, pending_difference)
                pending_difference = nil
            end
        end
        gfx.set(0.32, 0.35, 0.40, 1)
        gfx.rect(slider_x, slider_y - 2, slider_width, 4, true)
        gfx.set(0.30, 0.73, 0.53, 1)
        gfx.circle(slider_x + slider_width * difference / 10, slider_y, 7, true)
        gfx.setfont(1, 'Arial', 14)
        gfx.set(0.76, 0.78, 0.81, 1)
        text(slider_x - 5, 171, '0')
        text(slider_x + slider_width - 25, 171, '10 dB')
        text(18, 202, 'Quick:')
        for i, value in ipairs({ 1, 3, 6, 10 }) do
            local x = 78 + (i - 1) * 96
            gfx.set(0.23, 0.25, 0.29, 1)
            gfx.rect(x, 194, 86, 28, true)
            gfx.set(0.94, 0.94, 0.94, 1)
            text(x + 17, 201, value .. ' dB')
            if down and not held and inside(x, 194, 86, 28) then
                ambience.set_difference(project, value)
            end
        end
        local can_reset = not ambience.is_default_difference(buses)
        if can_reset then gfx.set(0.23, 0.25, 0.29, 1)
        else gfx.set(0.15, 0.16, 0.18, 1) end
        gfx.rect(18, 234, 184, 28, true)
        if can_reset then gfx.set(0.94, 0.94, 0.94, 1)
        else gfx.set(0.45, 0.47, 0.50, 1) end
        text(31, 241, 'Reset to default')
        gfx.set(0.76, 0.78, 0.81, 1)
        text(215, 241, 'A -3 dB / C +3 dB')
        if can_reset and down and not held and inside(18, 234, 184, 28) then
            ambience.set_difference(project, 3)
        end
        gfx.set(0.76, 0.78, 0.81, 1)
        gfx.setfont(1, 'Arial', 14)
        text(18, 277, 'Release slider to apply. Keys 1 / 2 / 3 switch ambience.')
        text(18, 295, 'Save the project to keep your settings.')
    elseif active then
        pending_difference = nil
        text(18, 65, 'Ambience buses changed. Close this window and rerun.')
    else
        pending_difference = nil
    end
    held = down
    gfx.update()
    r.defer(frame)
end
frame()
