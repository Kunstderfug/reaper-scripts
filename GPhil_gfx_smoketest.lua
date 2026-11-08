-- Minimal GFX smoke test for REAPER ReaScript (deferred/non-blocking)
-- Opens a window and exits on ESC or window close.

---@diagnostic disable-next-line: undefined-global
local reaper = reaper
---@diagnostic disable-next-line: undefined-global
local gfx = gfx
local background_root = debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])') or './'
local background = dofile(background_root .. 'lib/gfx_background.lua').new(gfx)

gfx.init("GPhil GFX Smoke Test", 520, 180)
gfx.setfont(1, "Arial", 20)

local function loop()
    background.draw()
    gfx.set(1, 1, 1, 1)
    gfx.x = 20
    gfx.y = 30
    gfx.drawstr("GFX window is alive.")
    gfx.x = 20
    gfx.y = 70
    gfx.drawstr("Press ESC or close the window.")
    gfx.update()

    local char = gfx.getchar()
    if char < 0 or char == 27 then
        gfx.quit()
        return
    end

    reaper.defer(loop)
end

loop()
