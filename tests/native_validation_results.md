# Native REAPER validation

Tested on 2026-10-14 in REAPER 7.82/macOS-arm64 with SWS, using a separate disposable application instance and resource directory. The normal REAPER project and preferences were untouched.

## Multiple regions and restoration

| Case | Native result |
| --- | --- |
| Two regions with bases 120 and 90 BPM | Four passes: A100, A120, B80, B90; eight valid Ogg/FLAC files |
| Overwrite all | Replaced all eight existing sentinel files; no overwrite prompts |
| Cancel on B80, keep partial files | Stopped before B90; full state restored |
| Cancel on B80, discard partial files | Stopped before B90; full state restored |

Each pass checked the live region tempo, selected region and scaled region duration. After every run, the test compared all original tempo/meter marker fields, including full flags (Set tempo and Set meter), positions in seconds and measures/beats, linear-tempo state, beat basis, custom 5/4 metronome pattern and project defaults. All five markers matched. Region bounds and selections, render settings and track state also matched. Exit cleanup was called again to check idempotence.

The native renderer and real Tempo Set source/modules were exercised. The harness supplied confirmed grid rows and applied equivalent native render settings instead of invoking the user’s preset actions. This checks render behavior without changing installed preset configuration. Cancellation used a temporary long second region to make the native Cancel button reachable.

Logs: [success](native-results/success.txt), [overwrite](native-results/overwrite.txt), [cancel/keep](native-results/cancel_keep.txt), [cancel/discard](native-results/cancel_discard.txt).

## Tested source fingerprints

```
5086f44a474bb5151f61c0e54c369ae7f1a372ea3d864e6891acfd4851749557  GPhil_tempoSet_render_gfx_direct.lua
57078c605ce9c957f939f5f912d229c41ba5b9f890cc99d2bd6b5022a3ad78da  lib/render_pass.lua
881407b330aecad97d05f1f05a82497424a1445a4522a6e4336827326ac8125d  lib/render_session.lua
8d8f35755deccc5e93463d65062f5d575ae13224c360bb8fa166a25ea28420a8  lib/tempo_map.lua
```

The deployed Tempo Set script and runtime modules were byte-identical to these tested sources. All eight offline regression suites passed; native-only harnesses skip outside REAPER.

## Portable demo with muted click track

Opened the saved `examples/tempo-set-demo/Tempo Set Demo.rpp` in native REAPER,
then ran actual Tempo Set source/modules with its saved grid ranges. Two click
passes (A120, B90) used selected tracks via master; four music passes
(A100, A120, B80, B90) used the master mix with CLICKTRACK muted. All twelve
Ogg/FLAC files had valid encoding headers and non-silent native render peaks.
The entire map, both region boundaries/selections, both track mute/selection
states, media item positions/lengths/playrates, saved grid settings and render
settings matched afterward. CLICKTRACK returned to its original muted state.

Repeated after replacing all twelve exact target files with sentinels: every
output was regenerated without an overwrite prompt, and all restoration checks
passed again. Preset application was adapted to native render settings and a
disposable output folder; installed user preset actions were not invoked.

Logs: [demo render](native-results/demo-render.txt),
[demo overwrite](native-results/demo-overwrite.txt).
