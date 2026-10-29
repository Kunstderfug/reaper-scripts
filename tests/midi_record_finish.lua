local finish = dofile('lib/midi_record_finish.lua')
local function fixture(fail)
    local item, unrelated, project = { chunk = 'recorded' }, { selected = true }, {}
    local state = { begins = 0, ends = 0, order = {} }
    local api = {
        EnumProjects = function() return project end,
        GetPlayStateEx = function() return 0 end,
        GetItemStateChunk = function(it) return true, it.chunk end,
        SetItemStateChunk = function(it, chunk) it.chunk = chunk; return true end,
        Undo_BeginBlock2 = function() state.begins = state.begins + 1 end,
        Undo_EndBlock2 = function() state.ends = state.ends + 1 end,
        UpdateArrange = function() end,
        SelectAllMediaItems = function(p, selected)
            assert(p == project and selected == false)
            unrelated.selected = false; item.selected = false
        end,
        SetMediaItemSelected = function(it, selected) it.selected = selected end,
        Main_OnCommandEx = function(command, _, p)
            assert(command == 40153 and p == project and item.selected and not unrelated.selected)
            state.order[#state.order + 1] = 'editor'
        end,
    }
    local services = {
        bounds = {
            plan = function(_, p, items, mode, opt)
                assert(p == project and items[1] == item and mode == 'both' and opt.lead_in == false)
                return { eligible = { item } }
            end,
            summary = function() return 'summary' end,
            apply = function(a)
                a.Undo_BeginBlock2(project); item.chunk = 'aligned'; a.Undo_EndBlock2(project)
                state.order[#state.order + 1] = 'align'; return 1
            end,
        },
        optimizer = { run = function(a, _, opt)
            assert(opt.prompt == false and opt.items[1] == item and opt.ccs == 'auto')
            assert(opt.tolerance == 4 and opt.jitter and item.chunk == 'aligned')
            state.order[#state.order + 1] = 'optimize'
            if fail then item.chunk = 'partial'; error('optimizer failure') end
            a.Undo_BeginBlock2(project); item.chunk = 'optimized'; a.Undo_EndBlock2(project)
            return { changed = 1 }
        end },
    }
    return api, { project = project, items = { item } }, services, state, item
end
local api, batch, services, state, item = fixture()
local result = finish.run(api, '', batch, nil, services)
assert(result.aligned == 1 and result.optimized == 1 and item.chunk == 'optimized')
assert(table.concat(state.order, ',') == 'align,optimize,editor')
assert(state.begins == 1 and state.ends == 1)
api, batch, services, state, item = fixture(true)
local ok, err = pcall(finish.run, api, '', batch, nil, services)
assert(not ok and err:find('Recorded items restored.', 1, true))
assert(item.chunk == 'recorded' and state.begins == 1 and state.ends == 1)
assert(table.concat(state.order, ',') == 'align,optimize')
api, batch, services, state = fixture()
batch.project = {}
assert(not pcall(finish.run, api, '', batch, nil, services) and state.begins == 0)
api, batch, services, state, item = fixture(true)
services.optimizer.run = function() error('Alignment-only must not invoke optimizer') end
local result = finish.run(api, '', batch, { optimize_cc = false }, services)
assert(result.aligned == 1 and result.optimized == 0 and item.chunk == 'aligned')
assert(table.concat(state.order, ',') == 'align,editor')
assert(state.begins == 1 and state.ends == 1)
print('PASS: recording finish ordering, explicit scope, single Undo, full-item rollback, editor selection, project guard')
