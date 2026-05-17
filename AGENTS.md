# Project Instructions

- REAPER GPHIL scripts deploy to `/Users/slav/Library/Application Support/REAPER/Scripts/GPhil`.
- After editing any `GPhil_*.lua` script in this repo, replace the matching file in that GPHIL folder with the edited version and verify the copy matches.
- For `GPhil_tempoSet_render_gfx_direct.lua`, selected regions are a filter only when one or more regions are selected. If no regions are selected, render all regions.
- In the GFX region grid, cross-row copy actions must preserve each row's automatically detected base tempo.
- In the GFX region grid, Save/Load stores per-project region settings and loads Min/Max/Step/Click while preserving each row's current detected Base.
