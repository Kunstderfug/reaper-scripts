# Instrument initialization before tempo-set renders

Every music pass submitted by `GPhil_tempoSet_render_gfx_direct.lua` enables
REAPER's native **delay render start to allow FX to initialize and load samples**
for at least two seconds. A longer enabled delay in the GPHIL_RENDER preset is
preserved. The setting is applied after the preset, for both Render now and
queued projects. Click passes keep their preset settings.

The delay does not add silence to the exported file or change region bounds,
MIDI events, CC curves, or output fades. Original render settings are restored
when the script finishes, is canceled, or fails.

This is initialization time, not a guaranteed instrument reset or musical
pre-roll. In particular, it does not guarantee that a remote Vienna Ensemble
Pro instrument clears its internal state, or prevent mechanical noises caused
by MIDI messages delivered when rendering actually begins. No blanket CC reset
or all-notes-off action is added: those can themselves produce modeled release
or mechanism sounds. Confirm the effect by comparing the same opening with and
without the delay. If the noise persists, identify the instrument and the
render-start messages before changing controller/reset behavior.

Reference: https://www.reaper.fm/sdk/reascript/reascripthelp.html#GetSetProjectInfo
(`RENDER_SETTINGS` and `RENDER_DELAY`).
