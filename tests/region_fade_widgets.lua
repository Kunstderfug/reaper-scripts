local widgets = dofile('lib/cc_widgets.lua')
local module = dofile('lib/region_fade_widgets.lua')
local project, regions, items, track = {}, {
    { id = 1, first = 10, last = 20, name = 'One', selected = true },
    { id = 2, first = 30, last = 40, name = 'Two', selected = true },
}, {}, {}
for _, span in ipairs({ {10, 5}, {15, 5}, {30, 5}, {35, 5} }) do
    items[#items + 1] = { D_POSITION = span[1], D_LENGTH = span[2], C_FADEINSHAPE = #items % 2,
        C_FADEOUTSHAPE = #items % 3, D_FADEINDIR = 0, D_FADEOUTDIR = 0, C_LOCK = 0 }
end
local changed, undo, messages, graph_lines = 0, 0, {}, 0
local api = {
    GetAppVersion = function() return '7.80' end,
    EnumProjects = function() return project end,
    CountMediaItems = function() return #items end,
    GetMediaItem = function(_, i) return items[i + 1] end,
    GetMediaItemTrack = function() return track end,
    GetMediaItemInfo_Value = function(item, key) return item[key] or 0 end,
    SetMediaItemInfo_Value = function(item, key, value) item[key] = value; changed = changed + 1; return true end,
    CountProjectMarkers = function() return #regions end,
    EnumProjectMarkers3 = function(_, i)
        local r = regions[i + 1]; return 1, true, r.first, r.last, r.name, r.id, 0
    end,
    GetRegionOrMarker = function(_, i) return regions[i + 1] end,
    GetRegionOrMarkerInfo_Value = function(_, r) return r.selected and 1 or 0 end,
    GetPlayStateEx = function() return 0 end,
    Undo_BeginBlock2 = function() undo = undo + 1 end,
    Undo_EndBlock2 = function() undo = undo - 1 end,
    PreventUIRefresh = function() end,
    UpdateArrange = function() end,
}
local g = { w = 660, h = 530, mouse_x = -1, mouse_y = -1, mouse_cap = 0 }
g.set = function() end; g.setfont = function() end
g.rect = function() end; g.measurestr = function(s) return #s * 7, 15 end
g.drawstr = function(s) messages[#messages + 1] = s end
g.line = function() graph_lines = graph_lines + 1 end
local ui = widgets.new(g)
local panel = module.new(api, g, ui)
panel.refresh(project, regions, { [1] = true, [2] = true })
local function draw(x, y, down)
    messages = {}; g.mouse_x, g.mouse_y, g.mouse_cap = x or -1, y or -1, down and 1 or 0
    ui.begin(); panel.draw()
end
local function click(x, y) draw(); draw(x, y, true) end
local function contains(value)
    for _, s in ipairs(messages) do if s == value then return true end end
    return false
end
draw()
assert(contains('R1  One') and contains('R2  Two'))
assert(contains('Mixed') and graph_lines > 0, 'Current differing shapes and actual previews must be drawn')

-- Opening a visual picker must not apply a shape from the same mouse press.
click(500, 140)
assert(panel.popup and panel.popup.side == 'out' and panel.popup.id == nil and changed == 0)
assert(contains('S curve / steep') and contains('Linear'))
click(400, 350) -- fifth native preset (zero-based shape 4)
assert(not panel.popup and undo == 0)
assert(items[2].C_FADEOUTSHAPE == 4 and items[4].C_FADEOUTSHAPE == 4)
assert(items[1].C_FADEOUTSHAPE == 0 and items[3].C_FADEOUTSHAPE == 2, 'Internal fades changed')
assert(panel.status:find('Changed 2 fades', 1, true))

-- Per-region incoming curve changes only that region's first item.
click(340, 210)
assert(panel.popup.id == 1 and panel.popup.side == 'in')
click(400, 220) -- second preset
assert(items[1].C_FADEINSHAPE == 1 and items[3].C_FADEINSHAPE == 0)
assert(items[2].C_FADEINSHAPE == 1 and items[4].C_FADEINSHAPE == 1)
assert(items[1].D_POSITION == 10 and items[1].D_LENGTH == 5)

click(340, 210)
assert(panel.key(27) and not panel.popup and not panel.key(27))
click(340, 210)
draw(); draw(25, 490, true)
assert(not panel.popup, 'Outside click should close picker')

-- A live selection change cancels the old picker and removes the row.
click(340, 210)
regions[1].selected = false
panel.refresh(project, regions, { [2] = true })
assert(not panel.popup)
draw(); assert(not contains('R1  One') and contains('R2  Two'))

-- Custom curvature must be identified, never presented as an exact preset.
items[3].D_FADEINDIR = .23
panel.refresh(project, regions, { [2] = true })
draw(); assert(contains('Custom'))
print('region_fade_widgets: all tests passed')
