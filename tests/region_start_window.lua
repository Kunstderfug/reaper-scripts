-- Exercise the real GFX frame loop, widgets and region planner without REAPER.
local window = dofile('lib/region_start_window.lua')
local function fixture()
    local function project(name)
        local track = {}
        return { version = 42, regions = {
            { id = 7, first = 10, last = 30, name = name .. ' opening', selected = false },
            { id = 9, first = 40, last = 50, name = name .. ' second', selected = false },
        }, items = {
            { D_POSITION = 10, D_LENGTH = 20, track = track,
                take = { D_PLAYRATE = 1, D_STARTOFFS = 5 } },
            { D_POSITION = 40, D_LENGTH = 10, track = track,
                take = { D_PLAYRATE = 1, D_STARTOFFS = 5 } },
        } }
    end
    local state = { time = 0, frames = {}, errors = {}, trims = 0, undo = 0 }
    state.projects = { project('Alpha'), project('Beta') }
    state.active = state.projects[1]
    local api = {
        EnumProjects = function() return state.active end,
        GetProjectStateChangeCount = function(p) return p.version end,
        time_precise = function() return state.time end,
        CountProjectMarkers = function(p) return #p.regions + 1 end,
        EnumProjectMarkers3 = function(p, index)
            if index == 0 then return 1, false, 1, 0, 'Ordinary marker', 1, 0 end
            local r = p.regions[index]
            return 1, true, r.first, r.last, r.name, r.id, 0
        end,
        GetRegionOrMarker = function(p, index) return p.regions[index] end,
        GetRegionOrMarkerInfo_Value = function(_, r) return r.selected and 1 or 0 end,
        CountMediaItems = function(p) return #p.items end,
        GetMediaItem = function(p, index) return p.items[index + 1] end,
        GetMediaItemInfo_Value = function(it, key)
            if key == 'D_FADEINLEN_AUTO' or key == 'D_FADEOUTLEN_AUTO' then return it[key] or -1 end
            return it[key] or 0
        end,
        SetMediaItemInfo_Value = function(it, key, value) it[key] = value; return true end,
        GetMediaItemTrack = function(it) return it.track end,
        CountTakes = function() return 1 end,
        GetTake = function(it) return it.take end,
        TakeIsMIDI = function() return false end,
        GetTakeNumStretchMarkers = function() return 0 end,
        GetMediaItemTakeInfo_Value = function(take, key) return take[key] end,
        BR_SetItemEdges = function(it, first, last)
            state.trims = state.trims + 1
            it.take.D_STARTOFFS = it.take.D_STARTOFFS - (it.D_POSITION - first)
            it.D_POSITION, it.D_LENGTH = first, last - first
            return true
        end,
        GetItemStateChunk = function() return true, 'backup' end,
        SetItemStateChunk = function() error('Unexpected rollback') end,
        SetProjectMarker3 = function(p, id, _, first, last, name)
            for _, r in ipairs(p.regions) do
                if r.id == id then r.first, r.last, r.name = first, last, name; return true end
            end
            return false
        end,
        GetPlayStateEx = function() return 0 end,
        Undo_BeginBlock2 = function() state.undo = state.undo + 1 end,
        Undo_EndBlock2 = function() state.undo = state.undo - 1 end,
        PreventUIRefresh = function() end,
        UpdateArrange = function() end,
        atexit = function(fn) state.exit = fn end,
        defer = function(fn) assert(not state.next); state.next = fn end,
        ShowMessageBox = function(message) state.errors[#state.errors + 1] = message end,
    }
    local pending, color = {}, {}
    local g = { w = 660, h = 530, mouse_cap = 0, mouse_x = -1, mouse_y = -1 }
    g.init = function(_, width, height) g.w, g.h = width, height end
    g.set = function(...) color = { ... } end
    g.setfont = function() end
    g.measurestr = function(value) return #value * 7, 15 end
    g.rect = function(x, y, w, h)
        pending[#pending + 1] = { x = x, y = y, w = w, h = h, color = color }
    end
    g.drawstr = function(value)
        pending[#pending + 1] = { text = value, x = g.x, y = g.y, color = color }
    end
    g.getchar = function()
        pending = {}
        local key = state.key or 0; state.key = nil; return key
    end
    g.update = function() state.frames[#state.frames + 1] = pending end
    g.quit = function() state.closed = true end
    local function pump(options)
        options = options or {}
        state.time = state.time + (options.elapsed or .21)
        state.key = options.key
        g.mouse_x, g.mouse_y, g.mouse_cap = options.x or -1, options.y or -1, options.down and 1 or 0
        local next_frame = assert(state.next, 'Window did not schedule another frame')
        state.next = nil; next_frame()
        assert(#state.errors == 0, table.concat(state.errors, '\n'))
        return state.frames[#state.frames]
    end
    local function click(x, y)
        pump() -- release the preceding click
        pump({ x = x, y = y, down = true })
        return pump()
    end
    return api, g, state, pump, click
end
local function text(frame, expected)
    for _, draw in ipairs(frame) do if draw.text == expected then return draw end end
    error('Text not drawn: ' .. expected)
end
local function absent(frame, value)
    for _, draw in ipairs(frame) do assert(draw.text ~= value, 'Unexpected text: ' .. value) end
end
local function apply_enabled(frame)
    for _, draw in ipairs(frame) do
        if not draw.text and draw.x == 440 and draw.y == 458 and draw.w == 200 and draw.h == 36 then
            return draw.color[1] == .62 -- the primary button's enabled accent
        end
    end
    error('Apply button was not drawn')
end

local api, g, state, pump, click = fixture()
window.open(api, g)
local frame = state.frames[1]
text(frame, '1')
text(frame, '[x] Extend fade-in too')
text(frame, 'SELECTED REGIONS (0)')
assert(not apply_enabled(frame), 'No selection must disable Apply')
absent(frame, 'R7  Alpha opening')
click(520, 475)
assert(state.trims == 0, 'Disabled Apply changed items')

-- Selection changes intentionally do not increment the project's dirty counter.
state.active.regions[1].selected = true
frame = pump()
text(frame, 'SELECTED REGIONS (1)')
text(frame, 'R7  Alpha opening')
text(frame, '1 regions / 1 opening items ready.')
assert(apply_enabled(frame) and state.active.version == 42)
absent(frame, 'R9  Alpha second')

state.active.regions[2].selected = true
frame = pump()
text(frame, 'SELECTED REGIONS (2)')
text(frame, 'R9  Alpha second')
text(frame, '2 regions / 2 opening items ready.')
state.active.regions[1].selected, state.active.regions[2].selected = false, false
frame = pump()
text(frame, 'SELECTED REGIONS (0)')
assert(not apply_enabled(frame))
absent(frame, 'R7  Alpha opening'); absent(frame, 'R9  Alpha second')

-- Switching projects rebuilds selection even though the dirty counters match.
state.projects[2].regions[2].selected = true
state.active = state.projects[2]
frame = pump()
text(frame, 'SELECTED REGIONS (1)'); text(frame, 'R9  Beta second')
absent(frame, 'R7  Alpha opening')
assert(apply_enabled(frame))
state.active = state.projects[1]
frame = pump()
text(frame, 'SELECTED REGIONS (0)'); assert(not apply_enabled(frame))
absent(frame, 'R9  Beta second')

-- Default Apply really extends the selected region by one second and adds its
-- fade-in. It leaves an unselected piece untouched.
state.active.regions[1].selected = true
pump(); click(520, 475)
assert(state.trims == 1 and state.undo == 0)
assert(state.active.items[1].D_POSITION == 9 and state.active.regions[1].first == 9)
assert(state.active.items[1].D_FADEINLEN == 1)
assert(state.active.items[2].D_POSITION == 40 and state.active.regions[2].first == 40)

-- A field click replaces the default value; invalid values disable Apply and
-- switching the fade option is reflected by the real widget rendering.
click(180, 115)
frame = pump({ key = string.byte('0') })
text(frame, '0|'); assert(not apply_enabled(frame))
text(frame, 'Enter a positive number of seconds.')
frame = click(490, 115)
text(frame, '[ ] Extend fade-in too')

-- Closing the window terminates the defer loop cleanly.
pump({ key = 27 })
assert(state.closed and not state.next)

-- A missing SWS API must produce a disabled button, not rely on a failed Apply.
api, g, state, pump, click = fixture()
api.BR_SetItemEdges = nil
state.active.regions[1].selected = true
window.open(api, g)
frame = state.frames[1]
text(frame, 'SWS extension required: BR_SetItemEdges is unavailable.')
assert(not apply_enabled(frame), 'Missing SWS must disable Apply')
click(520, 475)
assert(state.trims == 0 and state.undo == 0 and not state.closed)

-- Fix is independently available when extension is blocked: no SWS, no valid
-- duration, and a media item that begins before the region's current start.
state.active.items[1].D_POSITION = 9.5
state.active.version = state.active.version + 1
frame = pump()
text(frame, 'Fix region start')
text(frame, 'Fix start available')
click(180, 115)
frame = pump({ key = string.byte('0') })
text(frame, 'SELECTED REGIONS (1)')
assert(not apply_enabled(frame))
frame = click(450, 184)
assert(state.active.regions[1].first == 9.5)
assert(state.active.regions[1].last == 30)
assert(state.active.items[1].D_POSITION == 9.5 and state.trims == 0 and state.undo == 0)
text(frame, 'Fixed 1 region starts. Items unchanged. One Undo step.')
state.active.regions[1].selected = false
pump(); click(450, 184)
assert(state.active.regions[2].first == 40 and state.trims == 0)

-- Curve-only controls remain usable with an invalid extension amount and no SWS.
api, g, state, pump, click = fixture()
api.BR_SetItemEdges = nil
state.active.regions[1].selected, state.active.regions[2].selected = true, true
window.open(api, g)
click(180, 115); pump({ key = string.byte('0') })
frame = click(480, 40)
text(frame, 'Change ALL selected')
click(330, 140); click(200, 265) -- all opening fade-ins, shape 3
assert(state.active.items[1].C_FADEINSHAPE == 2 and state.active.items[2].C_FADEINSHAPE == 2)
assert(state.active.items[1].D_POSITION == 10 and state.active.items[2].D_POSITION == 40)
assert(state.trims == 0 and state.undo == 0)
click(520, 210); click(200, 441) -- only first region's closing fade-out, shape 7
assert(state.active.items[1].C_FADEOUTSHAPE == 6)
assert(not state.active.items[2].C_FADEOUTSHAPE)
assert(state.active.regions[1].first == 10 and state.active.regions[2].first == 40)
assert(state.trims == 0)

-- Existing extensions can reset their opening snap anchors independently.
api, g, state, pump, click = fixture()
api.BR_SetItemEdges = nil
state.active.regions[1].selected = true
state.active.items[1].D_SNAPOFFSET = 1.5
state.active.items[2].D_SNAPOFFSET = 2
window.open(api, g)
click(180, 115); pump({ key = string.byte('0') })
frame = click(385, 398)
assert(state.active.items[1].D_SNAPOFFSET == 0)
assert(state.active.items[2].D_SNAPOFFSET == 2)
assert(state.active.items[1].D_POSITION == 10 and state.active.regions[1].first == 10)
assert(state.trims == 0 and state.undo == 0)
local reported = false
for _, draw in ipairs(frame) do
    if draw.text and draw.text:match('^1 snap offsets reset;') then reported = true end
end
assert(reported)

print('region_start_window: all tests passed')
