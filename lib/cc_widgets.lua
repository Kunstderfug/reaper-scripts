-- Small immediate-mode GFX drawing helpers. Coordinates use a 660 x 530 canvas.
local M = {}
function M.new(g)
    local ui = { scale = 1, click = false, previous = false }
    local colors = {
        bg = { .055, .065, .085 }, panel = { .085, .10, .13 },
        text = { .91, .94, .98 }, muted = { .53, .60, .69 },
        accent = { .62, .55, .98 }, active = { .19, .16, .31 },
        teal = { .36, .85, .72 }, line = { .16, .19, .24 },
        hover = { .14, .17, .22 }, error = { 1, .55, .49 },
    }
    function ui.color(name) g.set(table.unpack(colors[name] or colors.text)) end
    function ui.rect(x, y, w, h, color)
        ui.color(color); g.rect(x * ui.scale, y * ui.scale, w * ui.scale, h * ui.scale, true)
    end
    function ui.text(x, y, value, size, color)
        ui.color(color or 'text')
        g.setfont(1, 'Arial', math.floor((size or 15) * ui.scale))
        g.x, g.y = x * ui.scale, y * ui.scale; g.drawstr(tostring(value))
    end
    function ui.hit(x, y, w, h)
        local mx, my = g.mouse_x / ui.scale, g.mouse_y / ui.scale
        return mx >= x and mx < x + w and my >= y and my < y + h
    end
    function ui.button(x, y, w, h, label, active, enabled, primary)
        if enabled == nil then enabled = true end
        local over = ui.hit(x, y, w, h)
        local color = primary and enabled and 'accent' or active and 'active'
            or over and enabled and 'hover' or 'panel'
        ui.rect(x, y, w, h, color)
        if active then ui.rect(x, y + h - 2, w, 2, 'accent') end
        g.setfont(1, 'Arial', math.floor(15 * ui.scale))
        local tw, th = g.measurestr(label)
        ui.text(x + (w - tw / ui.scale) / 2, y + (h - th / ui.scale) / 2,
            label, 15, enabled and 'text' or 'muted')
        return enabled and over and ui.click
    end
    function ui.wrap(x, y, value, width, size, color, max_lines)
        local line, count = '', 0
        g.setfont(1, 'Arial', math.floor(size * ui.scale))
        for word in tostring(value):gmatch('%S+') do
            local candidate = line == '' and word or line .. ' ' .. word
            if g.measurestr(candidate) / ui.scale > width and line ~= '' then
                ui.text(x, y, line, size, color); y = y + size + 5; count = count + 1
                if count >= (max_lines or 4) then return end
                line = word
            else line = candidate end
        end
        if line ~= '' then ui.text(x, y, line, size, color) end
    end
    function ui.begin()
        ui.scale = math.min(g.w / 660, g.h / 530)
        if ui.scale <= 0 then ui.scale = 1 end
        local down = g.mouse_cap & 1 ~= 0
        ui.click = down and not ui.previous; ui.previous = down
        ui.rect(0, 0, g.w / ui.scale, g.h / ui.scale, 'bg')
    end
    return ui
end
return M
