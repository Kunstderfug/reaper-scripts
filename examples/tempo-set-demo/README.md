# Tempo Set demo

Open **Tempo Set Demo.rpp** in REAPER. Keep the `Media` folder beside it.
The project is about 12 seconds long and needs no instrument plugins.

| Region | Detected base | Saved render tempos | Meter |
| --- | --- | --- | --- |
| Region_A | 120 BPM | 100, 120 BPM | 4/4, then 5/4 |
| Region_B | 90 BPM | 80, 90 BPM | 3/4, then 6/8 |

**DEMO MUSIC** contains a short arpeggio. **CLICKTRACK** contains a native
REAPER click source and is **muted by default**. It follows the project tempo
and meter map. Unmute it to audition the click; mute it again for music playback.

The five original map points include three meter-only marks, with **Set tempo
unchecked**, and a custom 5/4 click pattern. Region_B begins on a meter-only
3/4 mark, inheriting 90 BPM from the preceding tempo point.

## Try Tempo Set

1. Run `GPhil_tempoSet_render_gfx_direct.lua`.
2. Click **Load** in the grid to use the saved ranges above. Both rows have
   Click enabled. Neither region is selected, so both appear.
3. Choose **Render now**, or **Queue** to create queued projects.
4. Allow overwrite when repeating the run to test replacing existing outputs.

Expected: two click renders at the original base tempos and four music renders.
With a secondary format enabled, each render produces both formats.

Music filenames use `AUDIO/<region>/<project>_<region>_<tempo>`; click filenames
use `CLICKDATA/<project>_<region>_<base>`. The project starts with a relative
`Renders` destination. Your existing GPHIL_RENDER and GPHIL_CLICK preset actions
must be available; applying a preset can change the destination and formats.
Check those preset settings before using the demo interactively.

The click-only quick render script can also use this project's CLICKTRACK.
Rendering temporarily unmutes/selects that track, then restores its mute state.

## Restoration checks

After completion or cancel, the original tempo/meter map, all five points,
meter-only checkboxes, custom click pattern, region boundaries, track mute
states and selections should match the starting project. The click remains muted.
Small offline renders finish quickly; automated native cancellation checks use a
temporary long region to make Cancel reliably reachable.

See [native validation results](../../tests/native_validation_results.md).
