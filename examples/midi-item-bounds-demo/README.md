# MIDI item edges demo

Open `MIDI Item Bounds Demo.rpp` in REAPER. It contains three tracks and six
deliberately uneven MIDI items, plus 4/4, 3/4 and 7/8 sections and tempo changes.
There are no instrument plug-ins; the notes are for visual alignment testing.

Run `GPhil_quantizeMidiItemBounds_gfx.lua` from the Actions list. Choose selected
MIDI items, selected tracks, or the whole project, then Start + end, Start only,
or End only. Start adjustment pads outward. End adjustment uses the latest
note-off across all takes and rounds it up to a barline, trimming empty trailing
bars rather than rounding the recording stop time up. A note held across the
barline keeps the next bar. Late CCs/text do not add empty bars; controller-only
items and incomplete notes retain the original enclosing end bar.
Region starts and ends cap those expansions, including boundaries between
barlines. A right edge at a region end can still trim an empty note tail. Overlapping/nested
regions use the nearest containing boundary for each edge. Nearby region
overhangs trim inward when most of the item lies in that region and both edges
fit within its boundary bars. Spans into adjacent regions and longer overhangs
are preserved. Trimming can hide notes beyond the boundary; source MIDI data
and timing remain unchanged, with Undo restoring the original item edges.
For a quick action or keyboard shortcut, run
`GPhil_quantizeMidiItemBounds_selected.lua`: it adjusts both edges of selected
MIDI items immediately, without opening a window or showing a completion dialog.
An empty selection does nothing. Errors are reported in the REAPER console;
the last result (including skips) is also stored in transient ExtState
`GPhil_MIDI_Item_Bounds/last_report`.
If the first note starts on beat 1, start adjustment includes the preceding bar
when it is available after project time zero. Running again adds no more bars.
The lead-in also stops at region starts.

The script preserves note/event timing and properties, with one Undo step. It
does not automatically save. Non-repeating MIDI items have source looping
disabled so the added area stays silent. Locked items, repeating sources,
shared pooled MIDI, external MIDI, mixed audio/MIDI takes, and expansions that
would expose hidden MIDI events are skipped and listed in the scope report.

`lua tests/midi_item_bounds.lua` tests planning, scope, edge modes, exclusions,
event preservation, and rollback using a fake REAPER API.
`tests/native_midi_item_bounds.lua` runs inside REAPER, creates a new test tab,
checks all nine scope/mode combinations, and saves a fresh uneven demo. It
verifies exact opposite-edge preservation, event timing, idempotence, and Undo.
