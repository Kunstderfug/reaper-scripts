# Tempo and meter preservation

Read this before inheriting or changing marker capture/restore, scaling, or region-start adjustment. The live project's complete original map must survive queue creation, cancellation after mutation, and errors. A queued snapshot may contain the requested tempo change; the live project must return to its original state. An original-map render must leave the map untouched throughout.

## Marker attributes are part of the map

Capture before the first edit: marker order/positions, BPM, numerator/denominator, linear transitions, the complete flags integer, custom metronome patterns, and tempo beat basis where supported. Include project tempo/meter defaults changed by the script. Restore this metadata on every path that recreates or updates markers, including scaling and an existing marker at a region start.

Preflight the metadata APIs needed for a lossless round trip before destructive edits. An unavailable flags API is not equivalent to flags zero. Abort the modifying path with an actionable error if preservation cannot be established; an untouched-map mode can still work without these APIs. Inspect inherited helpers: copying a source is not evidence that it captures all these fields. Check every marker read; an incomplete capture must abort before mutation, rather than silently skip a point. Check write results and read back restored metadata to detect failed writes; report any restoration failure instead of claiming success.

### Write the complete flags integer once

```lua
local flags = reaper.GetSetTempoTimeSigMarkerFlag(proj, index, 0, false)
-- Capture flags alongside the other marker values before any edit.
-- After restoring/updating that marker, write the full saved value:
reaper.GetSetTempoTimeSigMarkerFlag(proj, restored_index, flags, true)
```

The final boolean selects read/write; it is not an individual bit's enabled state. Each write replaces the attribute mask. Looping over bits and writing each enabled bit separately overwrites earlier attributes. In the reported regression a meter-only marker's mask `3` became `2`, leaving a point with neither active meter nor explicit tempo.

| Mask bit | Meaning |
|---|---|
| `1` | Start a measure with a signature |
| `2` | Inherit tempo rather than set it |
| `4` | Permit a preceding partial measure |
| `8` | Start a metronome pattern |
| `16` | Reset the ruler grid |

Preserve the full integer, including any additional bits; do not reconstruct it from this table. Zero is a valid mask.

### Preserve meter-only semantics

A nonzero BPM returned by the getter does not prove that the marker sets tempo. Bit `2` represents REAPER's unchecked **Set tempo** state. Preserve it along with the signature bit: a meter-only marker stays meter-only, even when scaling the surrounding tempo map or updating an existing region-start point. Preserve explicit tempo-only and combined tempo/meter markers too.

Use the effective tempo at a meter-only point when detecting the region base. If it already matches the requested render speed, no explicit tempo override is needed. If the requested render intentionally needs a different tempo at that exact location, define and test a temporary override: retain the meter/options and deliberately clear bit `2` only at the override point. Preserve bit `2` at unrelated meter-only points and restore the original marker's checkbox state afterward. Changing stored BPM while retaining bit `2` does not establish an active override.

### Rebuild without losing attributes

Use one position system per `SetTempoTimeSigMarker` call: seconds with measure/beat `-1`, or measure/beat with seconds `-1`. Check insertion success and resolve the resulting index before applying metadata; indexes can change as the map is rebuilt. For custom patterns, require REAPER 7.28 or newer before mutation: that release added the `EXTENDED` getter and `SET:` setter form to the existing API. Preserve the pattern flag too. API presence alone does not establish setter support. Preserve beat basis through `GetSetTempoTimeSigMarkerBasis` where available.

See the official API entries for [marker flags](https://www.reaper.fm/sdk/reascript/reascripthelp.html#GetSetTempoTimeSigMarkerFlag), [marker positions](https://www.reaper.fm/sdk/reascript/reascripthelp.html#SetTempoTimeSigMarker), [metronome patterns](https://www.reaper.fm/sdk/reascript/reascripthelp.html#TimeMap_GetMetronomePattern), and [beat basis](https://www.reaper.fm/sdk/reascript/reascripthelp.html#GetSetTempoTimeSigMarkerBasis). Check the installed REAPER API documentation when a version differs.

## Sequential direct rendering

Use synchronous native rendering through action-bound `GetSetProjectInfo_String(proj, "RENDER_STATS", "42230", false)` and verify the expected outputs before changing tempo again. REAPER 6.68 introduced empty render statistics after cancellation, including when partial audio is kept; require that version or newer for this contract. An empty result or missing output ends the whole sequence. File existence alone cannot distinguish a completed render from an old or partial file. Check the installed API and [REAPER release history](https://www.reaper.fm/download-old.php?ver=6x) when changing the completion mechanism.

`RENDER_TARGETS` includes both primary and secondary encodings, but native `RENDER_STATS` contains one `FILE:` record per primary render. Compare statistics against primary targets, then verify every primary and secondary output exists. Obtain primary targets by temporarily clearing `RENDER_FORMAT2`, querying targets, and restoring the format in a protected cleanup before rendering; do not guess secondary paths from extensions because `$format` can change directories and names. Preserve a native statistics fixture in regression tests and verify sequential dual-format rendering in a disposable REAPER project when changing this gate.

When the user chooses overwrite-all for direct rendering, remove only existing exact paths from the current pass's validated `RENDER_TARGETS` immediately before rendering. Include secondary formats, stop if any removal fails, and preserve unrelated files and directories. Do not rely on the first native overwrite dialog to remember the choice across later render calls. Keep skip-existing behavior separate and test it without deletion. Never delete an entire region folder to suppress prompts.

Capture the originating project pointer and original state before edits. Register idempotent `atexit` cleanup before mutation so stopping the script also restores the map. Attempt each restoration independently, use project-specific Undo APIs and close the block even when another restoration fails, and report failures accurately. Resolve region starts from the current project after tempo changes; beat and seconds timebases can give different positions. Retain Queue as a separate dispatch when adding Render now.

## Regression checks before deployment

Exercise the actual derived implementation. Syntax checks cannot catch attribute-mask corruption.

- Round-trip a mixed map containing tempo-only, meter-only, and combined markers, with different BPMs, multiple positions, and linear transitions. Use the reported meter sequence `5/4 → 4/4 → 6/4 → 4/4`. Compare all saved fields, not only point count.
- Exercise every currently documented flag combination `0..31`. The mock must implement full-mask replacement and read-only queries, matching the API contract. Include custom patterns and nondefault beat bases when those attributes are supported.
- Exercise capture/restore, tempo scaling, and region-start adjustments at both an existing meter-only point and a new location. Any temporary point must disappear during cleanup. Verify requested tempo changes in each queued snapshot without activating tempo on unrelated meter-only points.
- Run the real main queue/render path through success and an injected failure after mutation. Compare the complete live map and the other captured state afterward. Cover cancellation if it can happen after edits, missing required metadata APIs before edits, failed marker reads/writes, and a cleanup error without skipping remaining restorations.
- For original-map mode, make marker writers/deleters and project tempo setters fail in the mock. Both normal rendering and failure cleanup must complete without calling them.

From the repository root, `lua tests/tempo_marker_flags.lua` tests the existing GFX helper paths. To exercise a new script with compatible helper names, run `lua tests/tempo_marker_flags.lua GPhil_<new>.lua`. That harness covers single-marker flags and values; it does not establish multi-marker positioning, pattern/basis preservation, or the complete queue/error path. Add those cases for a derivation that uses them. `tests/click_direct_render.lua` demonstrates main-path testing for untouched-map direct rendering.

For sequential rendering, also test multiple target tempos, a region away from time zero, both region timebases, cancellation on a later pass with partial audio kept, termination through `atexit`, and a missing preservation API before mutation.

A live REAPER check still needs a disposable project: record marker values and checkbox states, create the queue, compare the live map, inspect queued snapshots, and verify the isolated audio. Report automated coverage and live verification separately. Do not test destructive map reconstruction on the user's unsaved working project.
