# Dynamic brightness

Run `GPhil_dynamicBrightness.lua` from REAPER's Main action list. Its GPhil GFX
window adds or reuses a separate ReaEQ named **Dynamic brightness** on the
uniquely named BUS track. If there is no BUS, it uses the only selected track.
Existing effects, routing and faders are preserved. Save the project to retain
the EQ. Closing the window leaves native audio processing running, including
when rendering.

## Controls

The starting settings are a **2 kHz** high shelf with 1 octave bandwidth,
**−3 dB** cut limit and **+3 dB** boost limit, **−30 dBFS** full-cut level
and **−12 dBFS** full-boost level,
**50 ms** attack and **300 ms** release. Cut limit is adjustable from −12 to
0 dB; Boost limit from 0 to +12 dB. Their defaults and snap points stay −3/+3 dB. The detector listens to the full stereo
signal on channels 1/2 at the EQ input. At or below the lower level the shelf
reaches the cut limit; above the upper level it reaches the boost limit.
Between them it smoothly crosses zero. Setting Cut limit to 0 restores the
previous boost-only behaviour. These levels are
starting points: audition soft playing, pedal noises and loud passages.

Drag a slider to update ReaEQ live. Each drag is one Undo step. Small markers
show the defaults, with a gentle snap near each marker; drag away to release
it. Typed values are exact and apply on Enter or **Apply settings**. The window
also reads changes made directly in ReaEQ when no field is being edited.

**Open ReaEQ** opens only the owned effect in a floating window. **Enabled** toggles its bypass.
The signed live meter shows current shelf gain, including attenuation.
**Delta** auditions the difference between processed and original audio,
including cut, boost and phase changes. Other tracks routed to the master
continue playing; solo BUS to exclude their direct outputs. Click it again for the full processed output. Delta is a
native FX audition state, excluded from presets and last-used preferences;
it remains active until switched off, even if the GFX window is closed.

To inspect the follower natively, touch band 4's Gain control and choose
**Param → Parameter modulation/MIDI link**. Audio control drives Gain in the
positive direction. Changing the BUS fader is not the same as changing the
input signal reaching this effect. A loud mechanical noise can still trigger
it; adjust the input levels if necessary. The low-level cut reduces treble
in soft passages; it does not identify individual pedal noises.

## Presets and remembered settings

**Preset** offers Gentle (±1.5 dB), Balanced (±2 dB), and Full brightness
(±3 dB), all starting at 2 kHz with the default detector and timing values.
**Save preset…** stores all seven settings under your chosen name. Reusing a user
preset's name replaces it; **Delete preset** removes the selected user preset.
Built-in presets are protected. Presets are shared across projects.

The last successfully applied seven settings, including both the boost limit
cut limit and both input-level boundaries, are remembered globally for new projects. An existing
project reads its actual native EQ settings. Settings and the owned FX GUID
are also stored on the track with the project, including after moving the
FX into a container. Native Delta and bypass states are preserved when
adjusting settings, and are not part of a brightness preset. Legacy six-field
project settings and user presets load with a 0 dB cut limit, preserving their
original boost-only sound.

The window stays bound to its initial project and track. Switch back to edit
it, or reopen the script to target a different project. Automation envelopes
or extra modulation on the owned instance are rejected because they could
override the bounded setup. Out-of-range native follower changes are reported
instead of silently shown as valid settings.

## Gain calibration and verification

REAPER 7.84/macOS-arm64, 2026-10-30. The native EQ setter accepts linear
amplitude for band gain. `TrackFX_GetParam` reports unity as raw VST 0.25,
while `TrackFX_GetParamNormalized` reports unity as 0.5. Modulation baseline
uses the former; audio-control strength uses the latter's span. +3 dB is
normalized 0.56875626246134. Setup measures the installed plug-in's gain taper
from −12 to +12 dB in 0.1 dB steps, including raw baseline and normalized
automation values, and caches both curves on the track. Live edits adjust the follower's
baseline and strength using these curves without resetting its envelope or
modulation. Baseline sets the cut endpoint, and strength spans from that cut
to the requested boost endpoint.
Global output is set to unity through its raw amplitude parameter. Host Delta
and Wet controls use their normalized APIs. A full reconfiguration restarts
only the owned EQ to refresh REAPER’s audio-control input; routine live edits
avoid this restart.

Run `tests/native_dynamic_brightness.lua` in the currently running REAPER app.
It uses a new silent project tab and checks reuse, existing FX preservation,
Delta/bypass preservation, lower-limit live edits, preference persistence and
rollback after an
injected failure. It renders dynamic, Delta, unity and static +3 dB reference
WAVs, plus cut/boost and static −3 dB references, into `/tmp/gphil-dynamic-brightness-test/`, closes its saved test tab,
restores the original tab and restores prior global preferences. It yields
between renders so REAPER can refresh native modulation state; wait for the
original tab to return before running the analyzer. No additional
REAPER app instance is started. Then run:

```sh
python3 tests/dynamic_brightness_audio.py
lua tests/dynamic_brightness_window.lua
lua tests/dynamic_brightness_live.lua
lua tests/dynamic_brightness_presets.lua
```

The 2 kHz shelf produced settled 12 kHz boosts of 0, 0, 0, 0.881, 1.898,
2.808, 2.999, 2.999, 0 dB for successive peak input levels of −60, −40,
−30, −24, −18, −12, −6, −6, −60 dBFS. High-level results match the static
shelf reference; quiet segments and the return to quiet remain flat.

API reference: [REAPER ReaScript](https://www.reaper.fm/sdk/reascript/reascripthelp.html).

Native widened-range check reached approximately −11.995/+11.995 dB at 12 kHz,
matching static ±12 dB shelves. The ±3 dB default reached −2.999/+2.999 dB.
Delta restoration and live changes to a −1.5 dB cut limit were also verified.
