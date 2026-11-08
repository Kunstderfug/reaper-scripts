# GPhil GFX background

GFX windows share `lib/gfx_background.lua` and the bundled
`assets/images/bg-dark-desktop.png`. The PNG is a format conversion of
`gphil-flutter/assets/images/bg-dark-desktop.webp` (4467 × 2741); it is the same
artwork used by GPhil's desktop and dialogs.

The helper draws a centered cover crop at the dialogs' 0.5 opacity over a dark
fallback color. Window resizing preserves the artwork's proportions. Existing
controls, table rows and footer panels stay opaque for readability. A missing or
unreadable image leaves the solid fallback and does not interrupt the tool.

Use `dofile(root .. 'lib/gfx_background.lua').new(gfx)` once, then call
`background.draw()` at the start of each frame. Shared MIDI windows receive it
through `cc_widgets.lua`. Image slot 1023 is reserved for the source artwork.
The helper preserves the drawing destination, blend mode, color, alpha and cursor.
It reloads an image lost when a picker closes and the grid reinitializes GFX.

Deploy the helper and asset with the scripts, preserving those relative paths.
