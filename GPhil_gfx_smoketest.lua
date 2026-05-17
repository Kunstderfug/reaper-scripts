-- Minimal GFX smoke test for REAPER ReaScript (deferred/non-blocking)
-- Opens a window and exits on ESC or window close.

gfx.init("GPhil GFX Smoke Test", 520, 180)
gfx.setfont(1, "Arial", 20)

local function loop()
    gfx.set(0.1, 0.1, 0.12, 1)
    gfx.rect(0, 0, gfx.w, gfx.h, 1)
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
