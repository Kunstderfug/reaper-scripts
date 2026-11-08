-- Curve previews and the visual preset picker; region_fades owns item changes.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local fades = dofile(here .. 'region_fades.lua')
local regions_api = dofile(here .. 'region_start.lua')
-- Cockos cubic Bezier presets, published in SWS Breeder/BR_Util.cpp.
local curves = {
    { .5, .5, .5, .5 }, { .25, .5, .625, 1 }, { .375, 0, .75, .5 },
    { .25, 1, .5, 1 }, { .5, 0, .75, 0 }, { .375, 0, .625, 1 }, { .875, 0, .125, 1 },
}
local names = { 'Linear', 'Fast start', 'Slow start', 'Fast start / steep',
    'Slow start / steep', 'S curve', 'S curve / steep' }
local function cubic(t, a, b) return 3 * (1-t)^2 * t * a + 3 * (1-t) * t^2 * b + t^3 end
local function sample(shape, x)
    local p = curves[shape + 1] or curves[1]
    local lo, hi = 0, 1
    for _ = 1, 22 do
        local t = (lo + hi) / 2
        if cubic(t, p[1], p[3]) < x then lo = t else hi = t end
    end
    return cubic((lo + hi) / 2, p[2], p[4])
end
local function signature(project, regions, chosen)
    local result = tostring(project)
    for _, r in ipairs(regions) do if chosen[r.id] then result = result .. ':' .. r.id end end
    return result
end

function M.new(api, g, ui)
    local panel = { page = 1, status = 'Click a curve to change it. ALL changes all selected regions.' }
    function panel.refresh(project, regions, chosen)
        local key = signature(project, regions, chosen)
        if key ~= panel.signature then panel.popup = nil; panel.page = 1 end
        panel.signature, panel.project, panel.regions, panel.chosen = key, project, regions, chosen
        panel.data = fades.collect(api, project, regions, chosen)
        panel.rows = {}
        for _, r in ipairs(regions) do
            if chosen[r.id] then panel.rows[#panel.rows + 1] = r end
        end
        panel.page = math.max(1, math.min(panel.page, math.ceil(#panel.rows / 4)))
    end
    local function graph(x, y, w, h, shape, side)
        if not g.line then return end
        ui.color('text')
        local previous
        for i = 0, 48 do
            local px = i / 48
            local value = sample(shape, side == 'out' and 1 - px or px)
            local point = { (x + px * w) * ui.scale, (y + h - value * h) * ui.scale }
            if previous then g.line(previous[1], previous[2], point[1], point[2], true) end
            previous = point
        end
    end
    local function summary(side)
        local value, count
        count = 0
        for _, r in ipairs(panel.rows) do
            local data = panel.data[r.id]
            local candidate = side == 'in' and data.incoming or data.outgoing
            local n = #(side == 'in' and data.in_items or data.out_items)
            count = count + n
            if n > 0 then
                if not value then
                    value = {}; for key, v in pairs(candidate) do value[key] = v end
                elseif candidate.mixed or value.shape ~= candidate.shape or value.custom ~= candidate.custom
                    or value.dir_new ~= candidate.dir_new or value.dir2_new ~= candidate.dir2_new
                    or value.dir ~= candidate.dir then value.mixed = true end
            end
        end
        return value or {}, count
    end
    local function preview(x, y, w, value, count, id, side, blocked)
        local label = count == 0 and 'No items' or value.mixed and 'Mixed'
            or value.custom and 'Custom' or 'Shape ' .. ((value.shape or 0) + 1)
        local clicked = ui.button(x, y, w, 38, '', false, count > 0 and not blocked)
        if count > 0 and not value.mixed and not value.custom then
            graph(x + 8, y + 6, 62, 26, value.shape or 0, side)
        end
        ui.text(x + 80, y + 11, label, 12, count > 0 and 'text' or 'muted')
        if clicked then panel.popup = { id = id, side = side, value = value, just_open = true } end
    end
    local function select_shape(popup, shape)
        panel.popup = nil
        local ok, changed, skipped = xpcall(function()
            local current = api.EnumProjects(-1, '')
            local regions, chosen = regions_api.regions(api, current), {}
            for _, r in ipairs(regions) do chosen[r.id] = r.selected end
            assert(signature(current, regions, chosen) == panel.signature, 'Selection changed. Choose the curve again.')
            return fades.apply(api, current, regions, chosen, popup.id, popup.side, shape)
        end, debug.traceback)
        panel.status = ok and string.format('Changed %d fades; %d locked items skipped. One Undo step.', changed, skipped)
            or 'Stopped: ' .. tostring(changed)
        panel.error = not ok
        panel.refresh(panel.project, panel.regions, panel.chosen)
    end
    function panel.key(key)
        if key == 27 and panel.popup then panel.popup = nil; return true end
        return false
    end
    function panel.draw()
        local blocked = panel.popup ~= nil
        ui.text(20, 103, 'REGION FADES / ' .. #panel.rows .. ' SELECTED', 11, 'muted')
        ui.text(288, 103, 'FADE IN', 11, 'muted')
        ui.text(468, 103, 'FADE OUT', 11, 'muted')
        ui.text(20, 139, 'Change ALL selected', 15, 'accent')
        local incoming, n_in = summary('in')
        local outgoing, n_out = summary('out')
        preview(280, 125, 165, incoming, n_in, nil, 'in', blocked)
        preview(460, 125, 180, outgoing, n_out, nil, 'out', blocked)
        ui.rect(20, 177, 620, 1, 'line')
        for i = 1, 4 do
            local region = panel.rows[(panel.page - 1) * 4 + i]
            if region then
                local y, row = 192 + (i - 1) * 47, panel.data[region.id]
                g.setfont(1, 'Arial', math.floor(13 * ui.scale)); ui.color('text')
                g.x, g.y = 20 * ui.scale, (y + 12) * ui.scale
                g.drawstr('R' .. region.id .. '  ' .. region.name, 0, 265 * ui.scale, (y + 36) * ui.scale)
                preview(280, y, 165, row.incoming, #row.in_items, region.id, 'in', blocked)
                preview(460, y, 180, row.outgoing, #row.out_items, region.id, 'out', blocked)
            end
        end
        if #panel.rows == 0 then ui.text(20, 209, 'Select regions in REAPER\'s Region/Marker Manager.', 14, 'muted') end
        local pages = math.max(1, math.ceil(#panel.rows / 4))
        if ui.button(20, 395, 70, 26, 'Prev', false, panel.page > 1 and not blocked) then panel.page = panel.page - 1 end
        ui.text(103, 401, panel.page .. ' / ' .. pages, 12, 'muted')
        if ui.button(174, 395, 70, 26, 'Next', false, panel.page < pages and not blocked) then panel.page = panel.page + 1 end
        ui.text(20, 438, 'Opening fade-ins / closing fade-outs. Internal edits and lengths stay put.', 12, 'muted')
        ui.wrap(20, 466, panel.status, 620, 12, panel.error and 'error' or 'teal', 2)
        local popup = panel.popup
        if not popup then return end
        ui.rect(118, 110, 424, 380, 'line'); ui.rect(120, 112, 420, 376, 'bg')
        ui.text(134, 123, (popup.id and 'R' .. popup.id or 'ALL selected') .. ' / fade-' .. popup.side, 16, 'accent')
        local newly_open = popup.just_open
        popup.just_open = false
        if ui.button(463, 119, 62, 28, 'Close', false, not newly_open) then panel.popup = nil; return end
        for shape = 0, 6 do
            local y = 157 + shape * 44
            local checked = not popup.value.mixed and not popup.value.custom and popup.value.shape == shape
            if ui.button(132, y, 395, 40, '', checked, not newly_open) then select_shape(popup, shape); return end
            ui.text(141, y + 12, checked and 'x' or '', 13, 'teal')
            graph(169, y + 6, 120, 28, shape, popup.side)
            ui.text(309, y + 12, names[shape + 1], 13)
        end
        if ui.click and not newly_open and not ui.hit(118, 110, 424, 380) then panel.popup = nil end
    end
    return panel
end
return M
