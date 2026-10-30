-- GFX input and live region selection; region_start owns planning and editing.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local edges = dofile(here .. 'region_start.lua')
local widgets = dofile(here .. 'cc_widgets.lua')
local pins = dofile(here .. 'cc_pin.lua')
local curve_widgets = dofile(here .. 'region_fade_widgets.lua')
local snaps = dofile(here .. 'region_snap.lua')

function M.open(api, g)
    local ui = widgets.new(g)
    local curve_panel = curve_widgets.new(api, g, ui)
    local s = { text = '1', fade = true, chosen = {}, page = 1,
        status = 'Select regions in REAPER, then Apply.' }
    local function refresh()
        local project = api.EnumProjects(-1, '')
        local changed = project ~= s.project
        s.project = project
        s.regions = edges.regions(api, project)
        if changed then s.page = 1 end
        s.chosen = {}
        s.selection_key = ''
        for _, r in ipairs(s.regions) do
            s.chosen[r.id] = r.selected
            if r.selected then s.selection_key = s.selection_key .. r.id .. ',' end
        end
        s.plan = edges.plan(api, project, s.regions, s.chosen, tonumber((s.text:gsub(',', '.'))), s.fade)
        s.fix_plan = edges.plan_fix(api, project, s.regions, s.chosen)
        s.snap_plan = snaps.plan(api, project, s.regions, s.chosen)
        s.rows = {}
        local extension_rows = {}
        for _, row in ipairs(s.plan.rows) do extension_rows[row.region.id] = row end
        for _, fix in ipairs(s.fix_plan.rows) do
            if fix.chosen then
                local row = extension_rows[fix.region.id] or { region = fix.region, items = {}, issue = s.plan.problem }
                row.needs_fix = fix.first and math.abs(fix.first - fix.region.first) > 1e-7
                s.rows[#s.rows + 1] = row
            end
        end
        s.version = api.GetProjectStateChangeCount(project)
        curve_panel.refresh(project, s.regions, s.chosen)
        s.page = math.max(1, math.min(s.page, math.ceil(#s.rows / 5)))
    end
    local function apply(fix)
        -- Always rebuild from current item/take data. A different project must
        -- first be displayed for review rather than edited by an old button.
        if api.EnumProjects(-1, '') ~= s.project or api.GetProjectStateChangeCount(s.project) ~= s.version then
            refresh(); s.status = 'Project changed. Review the refreshed list, then Apply.'; return
        end
        local ok, result = xpcall(function()
            refresh()
            if fix == 'snap' then
                local changed, skipped = snaps.apply(api, s.project, s.regions, s.chosen)
                return { items = changed, skipped = skipped, report = string.format('%d snap offsets reset; %d locked items skipped.', changed, skipped) }
            end
            if fix then
                return { regions = edges.apply_fix(api, s.project, s.fix_plan), report = edges.fix_report(s.fix_plan) }
            end
            local regions, items = edges.apply(api, s.project, s.plan)
            return { regions = regions, items = items, report = edges.report(s.plan) }
        end, debug.traceback)
        s.error = not ok
        s.report = ok and result.report or tostring(result)
        s.status = ok and (fix == 'snap' and result.report .. ' One Undo step.'
            or fix and string.format('Fixed %d region starts. Items unchanged. One Undo step.', result.regions)
            or string.format('Extended %d regions / %d items. One Undo step.', result.regions, result.items))
            or 'Stopped. See Report for details.'
        refresh()
    end
    refresh()
    local pin = pins.open(api, g, 'GPhil | Extend region starts', 660, 530)
    api.atexit(function() g.quit() end)
    local function draw(key)
        ui.begin()
        ui.text(20, 12, 'GPHIL / AUDIO TOOLS', 10, 'accent')
        ui.text(20, 29, 'Region tools', 25)
        if ui.button(302, 28, 105, 26, 'Item edges', not s.curves) then s.curves = false end
        if ui.button(417, 28, 125, 26, 'Fade curves', s.curves) then s.curves = true; s.focus = false end
        if ui.button(554, 28, 86, 26, pin.enabled and 'Pinned' or 'Pin', pin.enabled, pin.window ~= nil) then
            pin.set(not pin.enabled)
        end
        ui.text(20, 66, s.curves and 'Selected regions only / change curves without extending media.'
            or 'Selected regions only / first item on each track.', 13, 'muted')
        ui.rect(20, 90, 620, 1, 'line')
        if s.curves then curve_panel.draw(); return end
        ui.text(20, 107, 'EXTEND LEFT BY', 11, 'muted')
        if ui.click then
            s.focus = ui.hit(155, 100, 116, 34)
            if s.focus then s.replace = true end
        end
        local edited = false
        if s.focus then
            if key == 1 then s.replace = true
            elseif key == 8 or key == 127 then
                s.text = s.replace and '' or s.text:sub(1, -2); s.replace = false; edited = true
            elseif key >= 32 and key <= 126 and string.char(key):match('[%d%.,]') then
                s.text = (s.replace and '' or s.text) .. string.char(key); s.replace = false; edited = true
            elseif key == 13 then s.focus = false end
        end
        if edited then refresh() end
        ui.rect(155, 100, 116, 34, s.focus and 'active' or 'panel')
        ui.text(167, 107, s.text .. (s.focus and '|' or ''), 17)
        ui.text(282, 110, 'seconds', 14, 'muted')
        if ui.button(365, 100, 275, 34, (s.fade and '[x] ' or '[ ] ') .. 'Extend fade-in too', s.fade) then
            s.fade = not s.fade; refresh()
        end
        ui.text(20, 146, s.fade and 'Existing audio and fade-in end keep their timeline positions.'
            or 'Existing audio stays in place. Fade-in length stays unchanged.', 12, 'muted')
        ui.text(20, 178, 'SELECTED REGIONS (' .. #s.rows .. ')', 11, 'muted')
        if ui.button(365, 170, 180, 28, 'Fix region start', false, #s.fix_plan.targets > 0) then
            s.focus = false; apply(true)
        end
        if ui.button(556, 170, 84, 28, 'Refresh') then refresh() end
        for i = 1, 5 do
            local row = s.rows[(s.page - 1) * 5 + i]
            if row then
                local y, r = 209 + (i - 1) * 34, row.region
                -- Clip text to its column even with long non-ASCII names.
                g.setfont(1, 'Arial', math.floor(13 * ui.scale))
                ui.color('text'); g.x, g.y = 20 * ui.scale, (y + 6) * ui.scale
                g.drawstr('R' .. r.id .. '  ' .. r.name, 0, 465 * ui.scale, (y + 28) * ui.scale)
                ui.text(478, y + 6, row.needs_fix and 'Fix start available'
                    or row.issue and 'Skip (report)' or #row.items .. ' items', 12,
                    row.issue and 'error' or 'teal')
            end
        end
        if #s.rows == 0 then ui.text(20, 222, 'Select regions in REAPER\'s Region/Marker Manager.', 14, 'muted') end
        local pages = math.max(1, math.ceil(#s.rows / 5))
        if ui.button(20, 385, 70, 26, 'Prev', false, s.page > 1) then s.page = s.page - 1 end
        ui.text(103, 391, s.page .. ' / ' .. pages, 12, 'muted')
        if ui.button(174, 385, 70, 26, 'Next', false, s.page < pages) then s.page = s.page + 1 end
        if ui.button(260, 385, 258, 26, 'Reset snap offset', false, #s.snap_plan.targets > 0) then
            s.focus = false; apply('snap')
        end
        if ui.button(530, 385, 110, 26, 'Report') then
            api.ShowMessageBox((s.report and s.report .. '\n\nCurrent preview:\n' or '') .. edges.report(s.plan)
                .. '\n\nFix region start:\n' .. edges.fix_report(s.fix_plan),
                'Extend region starts', 0)
        end
        local ready = api.BR_SetItemEdges ~= nil and not s.plan.problem and #s.plan.targets > 0
        ui.text(20, 429, not api.BR_SetItemEdges and 'SWS extension required: BR_SetItemEdges is unavailable.'
            or edges.report(s.plan):match('[^\n]+'), 13, ready and 'teal' or 'error')
        if ui.button(440, 458, 200, 36, 'Apply extension', false, ready, true) then
            s.focus = false; apply()
        end
        ui.wrap(20, 458, s.status, 403, 12, s.error and 'error' or 'muted', 3)
        ui.text(20, 510, 'Fix region start aligns regions only. Each Apply extends items + regions again.', 10, 'muted')
    end
    local function frame()
        local ok, err = xpcall(function()
            local key = g.getchar()
            if s.curves and curve_panel.key(key) then key = 0 end
            if key < 0 or key == 27 then g.quit(); return end
            if api.EnumProjects(-1, '') ~= s.project or api.GetProjectStateChangeCount(s.project) ~= s.version then
                refresh()
            elseif api.time_precise() >= (s.next_selection_check or 0) then
                local key = ''
                for _, r in ipairs(edges.regions(api, s.project)) do
                    if r.selected then key = key .. r.id .. ',' end
                end
                if key ~= s.selection_key then refresh() end
                s.next_selection_check = api.time_precise() + .2
            end
            draw(key); g.update(); pin.update(); api.defer(frame)
        end, debug.traceback)
        if not ok then g.quit(); api.ShowMessageBox(tostring(err), 'Extend region starts', 0) end
    end
    frame()
end
return M
