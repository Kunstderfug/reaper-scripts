# Native REAPER bridge

`GPhil_nativeBridge_start.lua` runs a deferred mailbox service inside the existing REAPER process. `tools/reaper_bridge.py` sends data requests from the terminal. No network listener, extra REAPER instance, UI automation, arbitrary script execution, or project saves are involved in export requests.

The installed startup stanza starts the service on future REAPER launches. Running the start action twice is idempotent. `stop` ends this session; starting the action or relaunching REAPER starts it again.

```sh
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py ping
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py projects
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py export-clicks \
  --project /absolute/path/Movement_AUTOPLAY.RPP --open-project \
  --region BEETHOVEN_1_3_EP_2_150 --output /absolute/path/review-clicks
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py export-clicks \
  --project /absolute/path/Movement_AUTOPLAY.RPP --open-project --saved-only \
  --region BEETHOVEN_1_3_EP_2_150 --output /absolute/path/review-clicks
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py stop
```

Without `--project`, exports read the current live project, including unsaved edits. With `--project`, an exact open path reads that live tab. `--open-project` permits opening the saved file in a temporary tab if it is not already open; the service closes only its own clean tabs and restores the previous selection, even on failure. It refuses exports while the target is playing or recording. Unsaved projects are never overwritten or silently reloaded.

`--saved-only` (opt-in; requires `--project`) exports only from the exact saved tab: the tab must be clean before and after reading, and `GetProjectStateChangeCount` must not change; otherwise nothing is written. A dirty open tab is refused, never reloaded or closed. The receipt always carries `project`, `dirtyBefore`/`dirtyAfter`, `stateChangeCountBefore`/`stateChangeCountAfter`, `savedOnly`, `openedOwnTab` and `exporterVersion`; the Python client additionally rejects a saved-only receipt that does not prove these (e.g. an older bridge still loaded in REAPER rejects the unknown `saved_only` field). A clean tab proves the in-memory project matches what was loaded/saved, not that the file on disk is unchanged since: callers needing that must hash the RPP before and after.

Each export creates a unique request subfolder under `--output`. Regions supply filenames and full time ranges. Every file contains GPhil JSON events with millisecond offsets and one-based beats. REAPER's measure and QN-to-time APIs supply tempo curves, meter, denominator beats, partial measures and pickup phase. Region ends are exclusive. Candidate beats come from `TimeMap_GetMeasureInfo` (`q0 + beat * 4 / denominator`), but membership is decided by REAPER's own `TimeMap2_timeToBeats` identity at each candidate time: a candidate must map back to the same measure, the same whole denominator beat, numerator and denominator. Candidates that native identity places in a later measure (overflow of a truncated/partial measure reset) are excluded and counted as `excludedCandidates`; if one lands on a whole beat, that later measure must itself have exported the same beat at the same millisecond. Disagreeing identity, beats missing from their owning measure, and two beats within one millisecond fail the export instead of being deduplicated or renumbered. Beat numbers are native denominator beats (compound meters count eighths); musical labels such as pickups or fermata pulses belong to approved manifests, not this exporter. All regions are validated before writing; files are never intentionally replaced. Interrupted exports can leave partial output; consult the response before using it.

This exports the native **beat grid**, not rendered click audio or custom CLICK-item overrides. Ordinary `AB...` metronome patterns are required by default. Custom patterns fail explicitly; `--grid-only` deliberately requests the underlying grid instead. Authored fermata clicks or other exceptions must be retained independently, as in the metered-solos verifier. This bridge does not publish/upload anything.

The mailbox is `/Users/slav/Library/Application Support/REAPER/GPhilBridge` with owner-only permissions. Requests are percent-encoded key/value lines, atomically renamed into `inbox`; responses and heartbeat are atomic JSON files. Session IDs and deadlines reject stale requests after restart. The service polls at 5 Hz, handles one request at a time on REAPER's main thread, and updates its heartbeat once a second. The Python client checks identity and times out with an explicit warning that an already-running export may finish. Other local REAPER automation must avoid simultaneous tab manipulation.

Deployment requires copying the entry point and all three `lib/native_*` modules (an already-running bridge keeps its loaded modules until REAPER restarts or the bridge is stopped and started) into `Scripts/GPhil`, and preserving any existing `Scripts/__startup.lua` content when installing its marked startup stanza. Mailbox directories must be private before first start. Remove that stanza to disable automatic startup.

Qualification: fixture tests cover the identity rules and saved-only checks (`lua tests/native_bridge.lua`, `lua tests/native_bridge_mailbox.lua <fresh dir>`). Live REAPER 7.86/macOS-arm64 checks on 2026-11-19 confirmed ordinary 4/4, a fractional-start 6/8 pickup, and a 4/4 measure reset at 0.75 s. The reset exported 0/500/750/1250/1750 ms with beat labels 1/2/1/2/3. Independent Python timing also matched all native events in source-timeline copies of Tchaikovsky 1/I (2,075 clicks), Beethoven 1/I (1,973), and Beethoven 3/I (1,881). These checks prove the tested native timing cases, not audible alignment of their orchestral recordings. `tools/qualify_autoplay.py` exercises generated-project rebuilds and native readback without publishing. API reference: https://www.reaper.fm/sdk/reascript/reascripthelp.html (`TimeMap_GetMeasureInfo`, `TimeMap2_QNToTime`, `TimeMap2_timeToBeats`, `TimeMap_GetMetronomePattern`).
