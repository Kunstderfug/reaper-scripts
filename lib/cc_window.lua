-- Presentation and selection state only; cc_optimizer owns every MIDI mutation.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local scope_module = dofile(here .. 'cc_scope.lua')
local optimizer = dofile(here .. 'cc_optimizer.lua')
local widgets = dofile(here .. 'cc_widgets.lua')
local selection = dofile(here .. 'cc_selection.lua')
local pin_module = dofile(here .. 'cc_pin.lua')
local names = { [1]='Mod wheel', [2]='Breath', [3]='CC 3', [7]='Volume', [10]='Pan',
    [11]='Expression', [13]='CC 13', [22]='CC 22', [64]='Sustain', [67]='Soft pedal' }
local function numbers(value)
    local result = {}; for n in value:gmatch('%d+') do result[#result + 1] = tonumber(n) end
    return result
end
function M.open(api, g, root)
    local ui = widgets.new(g)
    local pin
    local s = { follow='auto', scope='items', cc_mode='all', tolerance=4, jitter=true, selected={}, lanes={}, excluded={},
        page=0, status='Choose a scope, select CC lanes, then optimize.', sources=0 }
    local function refresh(preserve)
        local snapshot=selection.snapshot(api)
        local project = snapshot.project
        local same = project == s.project
        if s.follow=='auto' then s.scope=selection.resolve(snapshot,s.snapshot,s.scope) end
        s.snapshot=snapshot
        s.project = project
        s.revision = api.GetProjectStateChangeCount(project)
        local ok, result = pcall(function()
            local targets = scope_module.collect(api, project, s.scope)
            local eligible, excluded = scope_module.detect_ccs(targets)
            return { eligible=numbers(eligible), excluded=numbers(excluded), count=#targets }
        end)
        s.page, s.selected = 0, preserve and same and s.selected or {}
        if ok then
            s.lanes, s.excluded, s.sources, s.problem = result.eligible, result.excluded, result.count, nil
            if s.cc_mode=='all' then for _, cc in ipairs(s.lanes) do s.selected[cc] = true end end
        else
            s.lanes, s.excluded, s.sources = {}, {}, 0
            s.problem = tostring(result):gsub('^.-:%d+: ', '')
        end
    end
    local function chosen()
        local present={}; for _,cc in ipairs(s.lanes) do present[cc]=true end
        for _,cc in ipairs(s.excluded) do present[cc]=true end
        local list = {}; for cc in pairs(s.selected) do if present[cc] then list[#list + 1] = cc end end
        table.sort(list); return table.concat(list, ',')
    end
    local function optimize()
        -- Recollect the current selection at click time. Never retain take pointers
        -- between UI frames or operate on the previously scanned project tab.
        if api.EnumProjects(-1, '') ~= s.project then
            refresh(false); s.status='Project changed. Review the detected CCs before optimizing.'; return
        end
        if chosen() == '' then return end
        local ok, result = xpcall(function()
            return optimizer.run(api, root, { prompt=false, scope=s.scope, ccs=chosen(),
                tolerance=s.tolerance, jitter=s.jitter })
        end, debug.traceback)
        s.error = not ok
        if ok then
            s.status = result.changed == 0 and 'No changes needed.' or
                string.format('Done — %d MIDI sources optimized in %.3f s. One Undo step.', result.changed, result.seconds)
            s.backup = result.backup
            s.report = (result.backup and ('Backup: ' .. result.backup .. '\n\n') or '') .. (result.report or s.status)
        else
            s.report=tostring(result)
            s.status=s.report:find('Original MIDI restored.',1,true)
                and 'Stopped; original MIDI restored. Open Last report for details.'
                or 'Optimization stopped. Open Last report for failure and restore status.'
            api.ShowConsoleMsg('CC optimization failed:\n'..s.report..'\n')
        end
        refresh(true)
    end
    local function request_run()
        if s.pending or s.problem or chosen()=='' then return end
        s.pending=s.snapshot;s.status='Optimizing — preparing and verifying MIDI...';s.error=false
    end
    local function draw()
        ui.begin()
        ui.text(20, 12, 'GPHIL / MIDI TOOLS', 10, 'accent')
        ui.text(20, 29, 'CC gestures', 26)
        if s.report and ui.button(430, 28, 110, 26, 'Last report') then
            api.ShowMessageBox(s.report, 'CC optimization report', 0)
        end
        if pin then
            ui.text(554,35,pin.enabled and 'Pinned' or 'Pin',12,pin.enabled and 'accent' or 'muted')
            if ui.button(608,28,32,26,'',pin.enabled,pin.window~=nil) then
                if not pin.set(not pin.enabled) then s.status='Could not change the window pin.' end
            end
            ui.color(pin.enabled and 'accent' or 'muted')
            local function line(x,y,a,b) g.line(x*ui.scale,y*ui.scale,a*ui.scale,b*ui.scale) end
            line(619,34,630,34);line(621,34,621,40);line(628,34,628,40)
            line(621,40,617,45);line(628,40,632,45);line(617,45,632,45);line(625,45,625,50)
            if ui.hit(608,28,32,26) then
                ui.text(380,64,pin.window and 'Keep window on top: '..(pin.enabled and 'on' or 'off')
                    or 'Pin requires js_ReaScriptAPI',11,'muted')
            end
        end
        ui.text(20, 62, 'Fewer points. Continuous performance.', 13, 'muted')
        ui.rect(20, 84, 620, 1, 'line')
        ui.text(20, 96, '01  SCOPE', 11, 'muted')
        local scopes={{'auto','Auto selection'},{'items','MIDI items'},{'tracks','Tracks'},{'project','Whole project'}}
        for i,scope in ipairs(scopes) do
            if ui.button(20+(i-1)*157,114,149,32,scope[2],s.follow==scope[1]) then
                s.follow=scope[1]; if s.follow~='auto' then s.scope=s.follow end; refresh(true)
            end
        end
        ui.text(20,157,(s.scope=='items' and 'MIDI items' or s.scope=='tracks' and 'Tracks' or 'Project')
            ..' / '..s.sources..' MIDI sources',13,'teal')
        if ui.button(530,151,110,26,'Refresh') then refresh(true) end
        ui.text(20,188,'02  CC LANES',11,'muted')
        if ui.button(394,180,146,26,'Select detected') then
            s.cc_mode='all'; for _,cc in ipairs(s.lanes) do s.selected[cc]=true end
        end
        if ui.button(548,180,92,26,'Clear') then s.cc_mode='custom';s.selected={} end
        local pages=math.max(1,math.ceil(#s.lanes/12))
        for j=1,12 do
            local cc=s.lanes[s.page*12+j]
            if cc then
                local x,y=20+((j-1)%4)*157,216+math.floor((j-1)/4)*30
                if ui.button(x,y,149,26,string.format('%d  %s',cc,names[cc] or ('CC '..cc)),s.selected[cc]) then
                    s.cc_mode='custom';s.selected[cc]=not s.selected[cc] or nil
                end
            end
        end
        local rows=math.max(s.problem and 2 or 1,math.ceil(math.min(#s.lanes-s.page*12,12)/4))
        local footer=216+rows*30+4
        if #s.lanes==0 then ui.wrap(20,217,s.problem or 'No eligible continuous CC lanes detected.',620,13,'muted',2) end
        ui.text(20,footer,'CCs across selected sources; missing lanes are skipped.',11,'muted')
        if ui.button(20,footer+20,154,24,'Other used CCs...') then
            local menu={}
            for _,cc in ipairs(s.excluded) do
                menu[#menu+1]=(s.selected[cc] and '!' or '')..'CC '..cc..' (explicit override)'
            end
            if #menu>0 then
                g.x,g.y=20*ui.scale,(footer+44)*ui.scale
                local index=g.showmenu(table.concat(menu,'|'));local cc=s.excluded[index]
                if cc then s.selected[cc]=not s.selected[cc] or nil end
            end
        end
        if pages>1 then
            if ui.button(490,footer+20,30,24,'<') then s.page=(s.page-1)%pages end
            ui.text(534,footer+26,(s.page+1)..' / '..pages,11,'muted')
            if ui.button(610,footer+20,30,24,'>') then s.page=(s.page+1)%pages end
        end
        local shaping=footer+54
        ui.text(20,shaping,'03  SHAPING',11,'muted')
        ui.text(20,shaping+27,'Tolerance',14)
        if ui.button(104,shaping+20,28,28,'-') then s.tolerance=math.max(.5,s.tolerance-.5) end
        ui.text(146,shaping+27,string.format('%g',s.tolerance),14,'teal')
        if ui.button(177,shaping+20,28,28,'+') then s.tolerance=math.min(16,s.tolerance+.5) end
        if ui.button(224,shaping+20,416,28,(s.jitter and '[x]  ' or '[ ]  ')..'Repair jitter and collided fades',s.jitter) then s.jitter=not s.jitter end
        ui.text(20,shaping+55,'Lower = more detail; higher = fewer points.',11,'muted')
        ui.rect(20,shaping+77,620,1,'line')
        ui.text(20,shaping+88,s.scope=='project' and 'Backup first, then save the current project.'
            or 'Apply in place. One Undo step. No automatic save.',12,'muted')
        local count=#numbers(chosen())
        if ui.button(440,shaping+110,200,34,'Optimize '..count..' CC lanes',false,not s.problem and count>0,true) then
            request_run()
        end
        ui.wrap(20,shaping+111,s.status,405,12,s.error and 'error' or 'teal',2)
    end
    refresh(false)
    pin=pin_module.open(api,g,'GPhil | CC gestures',660,530)
    api.atexit(function() g.quit() end)
    local function frame()
        local ok, err = xpcall(function()
            local key = g.getchar()
            if key<0 or key==27 then g.quit(); return end
            local snapshot=selection.snapshot(api)
            local project = snapshot.project
            if s.pending then
                local pending=s.pending; s.pending=nil
                if not selection.same(snapshot,pending) then
                    refresh(true); s.status='Selection or project changed. Review the CCs and try again.'
                else optimize() end
            end
            -- Poll selection explicitly: selecting a track need not dirty the project.
            -- Limit full MIDI rescans while the user extends a large selection.
            if not selection.same(snapshot,s.snapshot) and api.time_precise()>=(s.next_refresh or 0) then
                refresh(true); s.next_refresh=api.time_precise()+.25
            end
            if key==13 then request_run() end
            draw(); g.update(); pin.update(); api.defer(frame)
        end, debug.traceback)
        if not ok then g.quit(); api.ShowMessageBox(tostring(err), 'CC gestures', 0) end
    end
    frame()
end
return M
