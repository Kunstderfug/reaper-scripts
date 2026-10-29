-- Quick action: pad selected MIDI item starts and ends to bars. No GFX window.
-- Last result is available in transient ExtState GPhil_MIDI_Item_Bounds/last_report.
local root = assert(debug.getinfo(1, 'S').source:sub(2):match('^(.*[/\\])'))
-- Prevent REAPER's automatic script Undo point for an empty/unchanged selection.
-- The bounds module supplies the explicit Undo block when items change.
reaper.defer(function() end)
local ok, result = xpcall(function()
    if reaper.CountSelectedMediaItems(0) == 0 then return 'No items selected.' end
    local bounds = dofile(root .. 'lib/midi_item_bounds.lua')
    local project = reaper.EnumProjects(-1, '')
    local plan = bounds.plan(reaper, project, 'items', 'both')
    local changed = bounds.apply(reaper, project, plan)
    return changed .. ' MIDI items aligned.\n' .. bounds.summary(plan)
end, debug.traceback)
reaper.SetExtState('GPhil_MIDI_Item_Bounds', 'last_report',
    ok and result or ('Failed: ' .. tostring(result)), false)
if not ok then reaper.ShowConsoleMsg('MIDI item edge alignment failed:\n' .. tostring(result) .. '\n') end
