-- Shares the MIDI CC optimizer's widgets, selection following and window pin.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local bounds = dofile(here .. 'midi_item_bounds.lua')
local widgets = dofile(here .. 'cc_widgets.lua')
local selection = dofile(here .. 'cc_selection.lua')
local pins = dofile(here .. 'cc_pin.lua')

function M.open(api, g)
    local ui = widgets.new(g)
    local s = { scope = 'items', follow = 'auto', mode = 'both', status = 'Choose a scope, then align item edges.' }
    local function refresh()
        local current = selection.snapshot(api)
        if s.follow == 'auto' then s.scope = selection.resolve(current, s.snapshot, s.scope) end
        s.snapshot, s.project = current, current.project
        local ok, result = pcall(bounds.plan, api, s.project, s.scope, s.mode)
        s.plan, s.problem = ok and result or nil, not ok and tostring(result) or nil
    end
    local function apply()
        local current = selection.snapshot(api)
        if not selection.same(current, s.snapshot) then
            refresh(); s.status = 'Selection or project changed. Review the scope and try again.'; return
        end
        local ok, result = xpcall(function()
            local plan = bounds.plan(api, s.project, s.scope, s.mode)
            local count = bounds.apply(api, s.project, plan)
            return { count = count, summary = bounds.summary(plan) }
        end, debug.traceback)
        s.error = not ok
        s.report = ok and result.summary or tostring(result)
        s.status = ok and ('Done - ' .. result.count .. ' MIDI items aligned. One Undo step.')
            or 'Stopped. Open Last report for details.'
        refresh()
    end
    refresh()
    local pin = pins.open(api, g, 'GPhil | MIDI item edges', 660, 530)
    api.atexit(function() g.quit() end)
    local function draw()
        ui.begin()
        ui.text(20, 12, 'GPHIL / MIDI TOOLS', 10, 'accent')
        ui.text(20, 29, 'MIDI item edges', 26)
        if s.report and ui.button(430, 28, 110, 26, 'Last report') then
            api.ShowMessageBox(s.report, 'MIDI item edges', 0)
        end
        if ui.button(554, 28, 86, 26, pin.enabled and 'Pinned' or 'Pin', pin.enabled, pin.window ~= nil) then
            pin.set(not pin.enabled)
        end
        ui.text(20, 62, 'Whole bars. Every note stays in place.', 13, 'muted')
        ui.rect(20, 84, 620, 1, 'line')
        ui.text(20, 96, '01  SCOPE', 11, 'muted')
        local scopes = { {'auto', 'Auto selection'}, {'items', 'MIDI items'}, {'tracks', 'Tracks'}, {'project', 'Whole project'} }
        for i, scope in ipairs(scopes) do
            if ui.button(20 + (i - 1) * 157, 114, 149, 32, scope[2], s.follow == scope[1]) then
                s.follow = scope[1]; if s.follow ~= 'auto' then s.scope = s.follow end; refresh()
            end
        end
        ui.text(20, 157, (s.scope == 'items' and 'Selected items' or s.scope == 'tracks'
            and 'Selected tracks' or 'Whole project') .. ' / ' .. (s.plan and s.plan.midi or 0) .. ' MIDI items', 13, 'teal')
        if ui.button(530, 151, 110, 26, 'Refresh') then refresh() end
        ui.text(20, 198, '02  ALIGN TO BARS', 11, 'muted')
        local modes = { {'both', 'Start + end'}, {'start', 'Start only'}, {'end', 'End only'} }
        for i, mode in ipairs(modes) do
            if ui.button(20 + (i - 1) * 210, 218, 200, 32, mode[2], s.mode == mode[1]) then
                s.mode = mode[1]; refresh()
            end
        end
        ui.text(20, 271, 'Extend enabled edges outward to the surrounding barlines.', 15)
        ui.text(20, 301, 'First note on beat 1: add one lead-in bar (when space allows).', 13, 'muted')
        ui.text(20, 325, 'Notes, CCs and other MIDI events keep their exact timing.', 13, 'muted')
        ui.text(20, 349, 'Padding adds silence; repeating or shared sources are skipped.', 12, 'muted')
        ui.rect(20, 382, 620, 1, 'line')
        local report = s.problem or s.plan and bounds.summary(s.plan) or ''
        ui.text(20, 396, report:match('[^\n]+') or '', 13, s.problem and 'error' or 'teal')
        local skipped = s.plan and next(s.plan.skipped)
        if skipped and ui.button(444, 390, 196, 28, 'Skipped items...') then
            api.ShowMessageBox(report, 'MIDI item edges - scope report', 0)
        end
        ui.text(20, 429, 'Apply in place. One Undo step. No automatic save.', 12, 'muted')
        local count = s.plan and #s.plan.targets or 0
        if ui.button(440, 455, 200, 34, 'Align ' .. count .. ' items', false, count > 0, true) then apply() end
        ui.wrap(20, 457, s.status, 405, 12, s.error and 'error' or 'teal', 3)
    end
    local function frame()
        local ok, err = xpcall(function()
            local key = g.getchar()
            if key < 0 or key == 27 then g.quit(); return end
            if not selection.same(selection.snapshot(api), s.snapshot)
                and api.time_precise() >= (s.next_refresh or 0) then
                refresh(); s.next_refresh = api.time_precise() + .25
            end
            if key == 13 and s.plan and #s.plan.targets > 0 then apply() end
            draw(); g.update(); pin.update(); api.defer(frame)
        end, debug.traceback)
        if not ok then g.quit(); api.ShowMessageBox(tostring(err), 'MIDI item edges', 0) end
    end
    frame()
end
return M
