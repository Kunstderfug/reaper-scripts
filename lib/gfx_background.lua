-- Shared GPhil artwork for GFX windows. UI controls draw normally over this layer.
-- The bundled PNG is converted from gphil-flutter's bg-dark-desktop.webp.
local M = {}
local here = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
local artwork = here .. '../assets/images/bg-dark-desktop.png'

function M.new(g, options)
    options = options or {}
    -- Reserve the last GFX image slot; current GPhil controls use no image slots.
    local slot = options.slot or 1023
    local opacity = options.opacity or 0.5 -- same artwork opacity as GPhil dialogs
    local fallback = options.fallback or { 0.055, 0.065, 0.085 }
    local attempted, loaded = false, false
    local function image_size()
        if not g.loadimg or not g.getimgdim or not g.blit then return end
        local width, height
        if loaded then
            width, height = g.getimgdim(slot)
            if width and height and width > 0 and height > 0 then return width, height end
            -- gfx.quit()/init() discards image slots, for example after a picker.
            attempted, loaded = false, false
        end
        if not attempted then
            attempted = true
            if g.loadimg(slot, options.path or artwork) == slot then
                width, height = g.getimgdim(slot)
                loaded = width and height and width > 0 and height > 0 or false
                if loaded then return width, height end
            end
        end
    end
    local background = {}
    function background.draw()
        local width, height = g.w or 0, g.h or 0
        if width <= 0 or height <= 0 then return end
        local dest, mode = g.dest, g.mode
        local red, green, blue, alpha = g.r, g.g, g.b, g.a
        local x, y = g.x, g.y
        g.dest, g.mode = -1, 0
        g.set(fallback[1], fallback[2], fallback[3], 1)
        g.rect(0, 0, width, height, true)
        local iw, ih = image_size()
        if iw then
            -- Centered cover keeps the original artwork proportions on resize.
            local scale = math.max(width / iw, height / ih)
            local sw, sh = width / scale, height / scale
            g.a = opacity
            g.blit(slot, 1, 0, (iw - sw) / 2, (ih - sh) / 2, sw, sh, 0, 0, width, height)
        end
        g.dest, g.mode = dest, mode
        g.r, g.g, g.b, g.a = red, green, blue, alpha
        g.x, g.y = x, y
    end
    return background
end
return M
