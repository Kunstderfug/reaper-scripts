-- Background resource failures must never stop an existing GFX workflow.
local backgrounds = dofile('lib/gfx_background.lua')
local function fixture(fail)
    local g = { w = 600, h = 900, r = .1, g = .2, b = .3, a = .7,
        x = 20, y = 30, dest = 17, mode = 1 }
    local state = { loads = 0, blits = {}, rects = 0 }
    function g.set(r, green, b, a) g.r, g.g, g.b, g.a = r, green, b, a end
    function g.rect() state.rects = state.rects + 1 end
    function g.loadimg(slot, path)
        state.loads = state.loads + 1
        assert(path:match('assets/images/bg%-dark%-desktop%.png$'))
        state.loaded = not fail
        return fail and -1 or slot
    end
    function g.getimgdim() return state.loaded and 4467 or 0, state.loaded and 2741 or 0 end
    function g.blit(...) state.blits[#state.blits + 1] = { ... } end
    return g, state
end
local g, state = fixture(false)
local background = backgrounds.new(g)
background.draw(); background.draw()
assert(state.loads == 1 and #state.blits == 2)
assert(g.r == .1 and g.g == .2 and g.b == .3 and g.a == .7)
assert(g.x == 20 and g.y == 30 and g.dest == 17 and g.mode == 1)
local portrait = state.blits[1]
assert(math.abs(portrait[6] / portrait[7] - g.w / g.h) < 1e-10)
assert(portrait[4] > 0 and portrait[5] == 0)
g.w, g.h = 1200, 300
background.draw()
local wide = state.blits[3]
assert(wide[4] == 0 and wide[5] > 0)
assert(wide[10] == 1200 and wide[11] == 300)
state.loaded = false -- image slots lost after gfx.quit/init
background.draw()
assert(state.loads == 2 and #state.blits == 4)
local failed, failed_state = fixture(true)
local fallback = backgrounds.new(failed)
fallback.draw(); fallback.draw()
assert(failed_state.loads == 1 and #failed_state.blits == 0 and failed_state.rects == 2)
local mock = { w = 600, h = 400, set = function() end, rect = function() end }
backgrounds.new(mock).draw() -- image APIs absent in headless UI tests
print('PASS: background resize, drawing-state restoration, context reload and missing-image fallback')
