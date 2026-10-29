-- Modeless GFX list shared by the renderer and the standalone track selector.
local M = {}
local section = 'GPHIL_STEM_LAYERS'

function M.show(r, gfx, model, project, options, done)
    options = options or {}
    local rows = model.discover(r, project)
    local choices = model.picker_rows(rows)
    local selected = {}
    local initial = options.selected or model.selected(rows, r)
    for _, row in ipairs(choices) do selected[row.guid] = initial[row.guid] or nil end
    if not options.selected and next(selected) == nil then
        local _, saved = r.GetProjExtState(project, section, 'selected_guids')
        local saved_guids = {}
        for guid in (saved or ''):gmatch('[^\n]+') do saved_guids[guid] = true end
        for _, row in ipairs(choices) do selected[row.guid] = saved_guids[row.guid] or nil end
    end
    local held, scroll, message = true, 0, ''
    gfx.init(options.title or 'Stem render layers', 540, 740)
    local function text(x, y, value)
        gfx.x, gfx.y = x, y
        gfx.drawstr(value)
    end
    local function inside(x, y, w, h)
        return gfx.mouse_x >= x and gfx.mouse_x < x + w
            and gfx.mouse_y >= y and gfx.mouse_y < y + h
    end
    local function finish(value)
        gfx.quit()
        done(value, rows)
    end
    local function frame()
        local key = gfx.getchar()
        if key < 0 or key == 27 then finish(nil); return end
        local active = r.EnumProjects(-1, '') == project
        local down = gfx.mouse_cap & 1 == 1
        local clicked = down and not held
        gfx.set(0.10, 0.11, 0.13, 1)
        gfx.rect(0, 0, gfx.w, gfx.h, true)
        gfx.setfont(1, 'Arial', 17)
        gfx.set(0.94, 0.94, 0.94, 1)
        text(18, 16, 'Choose layers to render')
        gfx.setfont(1, 'Arial', 14)
        gfx.set(0.76, 0.78, 0.81, 1)
        text(18, 43, 'Each enabled layer produces a separate stem file.')
        if not active then
            text(18, 90, 'Return to the original project tab to select layers.')
        else
            local count = #model.tracks(rows, selected)
            local function button(x, width, label, enabled, green)
                local hover = inside(x, 73, width, 32)
                if not enabled then gfx.set(0.15, 0.16, 0.18, 1)
                elseif green then gfx.set(0.20, 0.55, 0.39, 1)
                elseif hover then gfx.set(0.31, 0.34, 0.39, 1)
                else gfx.set(0.23, 0.25, 0.29, 1) end
                gfx.rect(x, 73, width, 32, true)
                gfx.set(enabled and 0.94 or 0.45, enabled and 0.94 or 0.47,
                    enabled and 0.94 or 0.50, 1)
                text(x + 12, 82, label)
                return enabled and hover and clicked
            end
            if button(18, 140, options.confirm_label or 'Continue', count > 0, true) then
                -- Validate before saving or changing any track selection.
                local valid, err = model.validate(r, project, rows, selected)
                if not valid then
                    message = err
                    held = down
                    gfx.update()
                    r.defer(frame)
                    return
                end
                local guids = {}
                for _, row in ipairs(choices) do
                    if selected[row.guid] then guids[#guids + 1] = row.guid end
                end
                r.SetProjExtState(project, section, 'selected_guids', table.concat(guids, '\n'))
                finish(selected)
                return
            end
            if button(170, 66, 'All', #choices > 0) then
                for _, row in ipairs(choices) do selected[row.guid] = true end
            end
            if button(248, 76, 'None', #choices > 0) then selected = {} end
            if button(336, 84, 'Cancel', true) then finish(nil); return end
            local top, row_height = 122, 27
            local visible = math.max(1, math.floor((gfx.h - top - 66) / row_height))
            if gfx.mouse_wheel ~= 0 then
                scroll = scroll + (gfx.mouse_wheel > 0 and -3 or 3)
                gfx.mouse_wheel = 0
            end
            scroll = math.max(0, math.min(scroll, #choices - visible))
            if #choices == 0 then
                text(18, top + 8, 'No STEMS folder or legacy stem buses found in this project.')
            end
            for i = scroll + 1, math.min(#choices, scroll + visible) do
                local row = choices[i]
                local y = top + (i - scroll - 1) * row_height
                local hover = inside(18, y, gfx.w - 36, row_height)
                if hover then gfx.set(0.19, 0.21, 0.25, 1)
                elseif row.kind ~= 'stem' then gfx.set(0.14, 0.16, 0.19, 1)
                else gfx.set(0.11, 0.12, 0.14, 1) end
                gfx.rect(18, y, gfx.w - 36, row_height - 1, true)
                local x = 27 + math.min(row.display_depth, 5) * 16
                gfx.set(0.40, 0.44, 0.49, 1)
                gfx.rect(x, y + 5, 16, 16, false)
                if selected[row.guid] then
                    gfx.set(0.30, 0.73, 0.53, 1)
                    gfx.rect(x + 3, y + 8, 10, 10, true)
                end
                gfx.set(0.94, 0.94, 0.94, 1)
                text(x + 26, y + 6, row.label)
                gfx.set(0.57, 0.61, 0.66, 1)
                local name_width = gfx.measurestr(row.name)
                text(math.max(x + 240, gfx.w - name_width - 30), y + 6, row.name)
                if hover and clicked then model.toggle(choices, selected, i) end
            end
            gfx.set(0.76, 0.78, 0.81, 1)
            text(18, gfx.h - 49, message ~= '' and message or count .. ' layer(s) enabled')
            text(18, gfx.h - 27, 'Sections render as one stem. Instruments are selected separately.')
        end
        held = down
        gfx.update()
        r.defer(frame)
    end
    frame()
end

return M
