# Native REAPER bridge

`GPhil_nativeBridge_start.lua` runs a deferred mailbox service inside the existing REAPER process. `tools/reaper_bridge.py` sends data requests from the terminal. No network listener, extra REAPER instance, UI automation, arbitrary script execution, or project saves are involved in export requests.

The installed startup stanza starts the service on future REAPER launches. Running the start action twice is idempotent. `stop` ends this session; starting the action or relaunching REAPER starts it again.

```sh
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py ping
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py projects
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py export-clicks \
  --project /absolute/path/Movement_AUTOPLAY.RPP --open-project \
  --region BEETHOVEN_1_3_EP_2_150 --output /absolute/path/review-clicks
python3 /Volumes/DEV/reaper_scripts/tools/reaper_bridge.py stop
```

Without `--project`, exports read the current live project, including unsaved edits. With `--project`, an exact open path reads that live tab. `--open-project` permits opening the saved file in a temporary tab if it is not already open; the service closes only its own clean tabs and restores the previous selection, even on failure. It refuses exports while the target is playing or recording. Unsaved projects are never overwritten or silently reloaded.

Each export creates a unique request subfolder under `--output`. Regions supply filenames and full time ranges. Every file contains GPhil JSON events with millisecond offsets and one-based beats. REAPER's measure and QN-to-time APIs supply tempo curves, meter, denominator beats, partial measures and pickup phase. Region ends are exclusive. All regions are validated before writing; files are never intentionally replaced. Interrupted exports can leave partial output; consult the response before using it.

This exports the native **beat grid**, not rendered click audio or custom CLICK-item overrides. Ordinary `AB...` metronome patterns are required by default. Custom patterns fail explicitly; `--grid-only` deliberately requests the underlying grid instead. Authored fermata clicks or other exceptions must be retained independently, as in the metered-solos verifier. This bridge does not publish/upload anything.

The mailbox is `/Users/slav/Library/Application Support/REAPER/GPhilBridge` with owner-only permissions. Requests are percent-encoded key/value lines, atomically renamed into `inbox`; responses and heartbeat are atomic JSON files. Session IDs and deadlines reject stale requests after restart. The service polls at 5 Hz, handles one request at a time on REAPER's main thread, and updates its heartbeat once a second. The Python client checks identity and times out with an explicit warning that an already-running export may finish. Other local REAPER automation must avoid simultaneous tab manipulation.

Deployment requires copying the entry point and all three `lib/native_*` modules into `Scripts/GPhil`, and preserving any existing `Scripts/__startup.lua` content when installing its marked startup stanza. Mailbox directories must be private before first start. Remove that stanza to disable automatic startup.

Validation: `lua tests/native_bridge.lua`; native terminal export can be compared with an independently generated REAPER click JSON. API reference: https://www.reaper.fm/sdk/reascript/reascripthelp.html (`TimeMap_GetMeasureInfo`, `TimeMap2_QNToTime`, `TimeMap2_timeToBeats`, `TimeMap_GetMetronomePattern`).
