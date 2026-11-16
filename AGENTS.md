# Project Instructions

- Always use the currently running REAPER app for native checks and UI work. Do not start additional REAPER instances.
- For native click exports or open-project status, use `python3 tools/reaper_bridge.py` first. Read `docs/native-reaper-bridge.md` for live/saved project selection, authored-click exceptions, and startup recovery.
- In GPhil work, “extend a region/section” always means include the complete intervening piano/solo passage through the next section's musical entry. Establish the bar/beat count from the score first, account for pickups and source preparation offsets, and extend the timeline and clicks through that passage while preserving existing audio. Completion requires verified solo coverage and the correct next entry, not just a moved region endpoint. Use the `reaper-gphil-autoplay` skill's metered-solo reconstruction branch for this work.
- REAPER GPHIL scripts deploy to `/Users/slav/Library/Application Support/REAPER/Scripts/GPhil`.
- After editing any `GPhil_*.lua` script in this repo, replace the matching file in that GPHIL folder with the edited version and verify the copy matches.
- For `GPhil_tempoSet_render_gfx_direct.lua`, selected regions are a filter only when one or more regions are selected. If no regions are selected, render all regions.
- In the GFX region grid, cross-row copy actions must preserve each row's automatically detected base tempo.
- In the GFX region grid, Save/Load stores per-project region settings and loads Min/Max/Step/Click while preserving each row's current detected Base.
