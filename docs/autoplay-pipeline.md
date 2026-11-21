# Data-driven AUTOPLAY and click delivery

The movement manifest owns reviewed timing decisions. Original orchestral RPPs,
Sanity snapshots, audio, OPUS references and score evidence remain separate inputs.
Rebuilding does not interpret a PDF or guess a fermata. An unresolved decision
produces a question and prevents a delivery candidate.

## REAPER action

Install once from this checkout:

```sh
python3 tools/install_autoplay_action.py
```

In REAPER's Actions list, load `Scripts/GPhil/GPhil_autoplay_pipeline.lua`.
Assign a toolbar button or shortcut if desired. Choose a movement manifest, then:

- **Build project** writes a separate AUTOPLAY copy and `regions.csv`.
- **Build and check clicks** also exports native per-region click JSON and compares it with the OPUS reference.
- **Build, check and preview upload** adds a read-only remote delivery preview.
- **Build, check and upload** runs the same gates, uploads verified JSON and publishes the matching score refresh metadata.

The action uses `BUILD` beside the selected manifest. Python runs outside REAPER
so the native bridge can answer requests. The action starts the bridge inside the
existing instance; it does not launch another REAPER. Installation records the
checkout, Python executable and FFmpeg tool directories beside the action, so a
launch from Applications does not depend on a shell's PATH. Reinstall after
moving these tools.

Set REAPER ExtState `GPhil_AutoplayPipeline/envFile` to a private credential-file
path when using the upload actions from the toolbar. The command line accepts
`--env-file` and `--secrets-plist` before its subcommand. No credential belongs in
a movement manifest, report, tracked file or command-line argument value.

## Prepare a movement

Fetch a fresh published Sanity snapshot with the existing Scoremaker CLI, or use:

```sh
python3 tools/autoplay.py --env-file /private/path/credentials.env fetch \
  --project-id b8uar5wl --dataset production --score-id SCORE_ID \
  --output /path/to/new-score-snapshot.json

python3 tools/autoplay.py prepare \
  --source /path/to/ORCHESTRAL.RPP \
  --template /path/to/GPHIL_AUTOPLAY.RPP \
  --sanity-snapshot /path/to/new-score-snapshot.json \
  --movement-key MOVEMENT_KEY --project-root /path/to/G-PHIL \
  --output /path/to/movement.json

python3 tools/autoplay.py questions /path/to/movement.json
```

`prepare` joins exact source region names to Sanity section keys, retains the
source tempo/meter observations and selects matching default-tempo media when
available. Filename BPM is a discovery key, not proof of actual rendered speed.
It preserves marker/region namespaces and selected-region flag bits. Existing
manifests are never replaced by another preparation run.

Review scale, preparation offsets, measure phase, handoffs, solo coverage and
fermatas against evidence. Pin any added score or measurement artifact in
`fingerprints`. A section's `decision` records `approved`, `reviewer`, `evidence`,
`source_to_render_scale` and `audio_sha256`. A Sanity handoff also needs an explicit
`handoff_basis` of `source` or `render`. Approval is a record of an actual review,
not a switch to turn on to suppress errors.

### Recover conflicting legacy timing as data

Unsupported tempo records, custom source patterns and coincident tempo events
remain in `raw_source_timing` with line-specific `source_timing_issues`. The
original RPP stays unchanged. Once the evidence has been reviewed, add a complete
`source_timing_override` with canonical `points` and `meter_anchors`, `approved`,
`reviewer` and a pinned `evidence` path. Tempo points use seconds, BPM and shape
0 (linear) or 1 (step); meter anchors use seconds, numerator and denominator.
Both lists start at zero and increase; every meter anchor needs a tempo point.

After the actual review, record `approved_sha256` from
`autoplay_lib.manifest.timing_review_sha256(manifest)`. It binds the exact
replacement, reviewer and pinned source/evidence. Changing the replacement
invalidates approval. Loading and compiling still re-read the original source;
deleting its recorded issues cannot bypass them. An override is a reviewed
replacement for conflicting evidence, not an automatic repair.

A between-beat meter reset uses `reset: true` on that anchor and an approved
`partial_measure_decision` with `policy: "reset"`, reviewer and pinned evidence.
The writer emits the qualified native reset flag `5`. These decisions also stay
subject to native readback and the full OPUS comparison.

## A one-value fermata change

For a constant-100 BPM section beginning at source time zero in 2/4, the final
beat of its first bar is 0.6–1.2 seconds. A reviewed hold can be represented by:

```json
{
  "source_seconds": 0.6,
  "source_end_seconds": 1.2,
  "duration_beats": 2,
  "window": "verified_solo",
  "approved": true,
  "reviewer": "Author",
  "evidence": "reviewed-count.json"
}
```

Place this record in the section's `fermatas` array and pin the evidence file.
`duration_beats: 2` makes that one beat run at 50 BPM and restores 100 BPM at
1.8 seconds. Changing only the value to 3 makes it run at 33⅓ BPM and restores
at 2.4 seconds. Following handoffs and section placements are recomputed.
It remains one held beat; no extra audible pulse is implied.

An explicitly measured, reviewed solo/silent hold can instead use
`duration_seconds`. Choose one duration unit. A hold inside fixed orchestral
audio needs compatible-render evidence or a new render. The pipeline does not
stretch orchestra recordings to conceal a conflict. Custom inserted/suppressed
audible pulses currently require a separately qualified click-render path and
block generation rather than being represented only in JSON.

## Build, evaluate and deliver

```sh
python3 tools/autoplay.py build movement.json --output BUILD
python3 tools/autoplay.py evaluate movement.json --output BUILD
python3 tools/autoplay.py --env-file /private/path/credentials.env \
  deliver movement.json --output BUILD

# One invocation: rebuild, native evaluation, remote preview.
python3 tools/autoplay.py --env-file /private/path/credentials.env \
  run movement.json --output BUILD

# Same gates, followed by upload and publication.
python3 tools/autoplay.py --env-file /private/path/credentials.env \
  run movement.json --output BUILD --publish
```

The writer preserves full rate-1 audio, Time-attached orchestra lanes, the Beats
project timebase, native Click Source and separate muted OPUS reference lane.
For `<SOURCE MP3>` items, the writer emits `FILE "<path>" 1` (never omitting the
trailing `1` or writing `0`) so REAPER strips MP3 Xing/LAME encoder and decoder
padding (~47 ms at 48 kHz for LAME MP3s) instead of loading in legacy mode.
It preserves longer authored regions and extends shorter ones to cover audio.
Auto-continue handoffs remain separate from region ends. Source gaps do not
determine auto placement. For manual boundaries without an explicit
`manual_gap_seconds`, the builder snaps the incoming section forward from
`prior_end + scaled_source_gap` onto the next bar/beat matching the incoming
section's meter and phase on the actual assembled output grid (if both meter
and pickup phase change across the gap, it places a clean meter change at the
preceding bar line in the silent gap). Set `manual_gap_seconds` explicitly to
bypass snapping. Rebuilding refuses a generated RPP edited outside its
matching build receipt; adopt the edit into the manifest or routing template.

Evaluation requires the running native bridge and clean saved candidate. Because
`evaluate()` already refuses any RPP whose SHA-256 differs from its build
receipt, `audit_rpp_integrity` acts as a text-level writer-regression and
integrity guard before invoking REAPER (it does not read back REAPER's decoded
audio PCM): it verifies project `TIMELOCKMODE 1`, track/item `BEAT` timebases,
`<SOURCE MP3>` trailing `1` (gapless padding compensation), strict `PLAYRATE 1`
and `SOFFS 0`, orchestra item `LENGTH` and `POSITION` parity, OPUS item
presence and `POSITION` parity (within `1e-6 s`), and that every media `FILE`
path resolves on disk (preventing REAPER's modal Missing Files dialog). It then
checks exact region sets/bounds and predicted events against REAPER, and detects
OPUS onsets with the Scoremaker peak/onset rules. There is no automatic fit that
shifts the reference to hide a discrepancy. `comparison.time_scale` and
`comparison.offset_ms` must represent reviewed mappings.

Every remaining OPUS difference is recorded. An intentional exact discrepancy set
can be approved with its `approved_discrepancy_sha256` and `approval_note` after
review. The fingerprint also includes scale, offset and tolerance. A non-identity
scale/offset or tolerance above 3 ms requires explicit approval even if it makes
all events align. Comparison always covers the complete files: `start_ms` and
`end_ms` windows are rejected. A different discrepancy set invalidates that approval. Native-grid
disagreements cannot be approved away. Grid readback is not an audible playback
or orchestral listening claim.

The evaluation receipt binds the manifest, source/template/media, generated RPP,
native exporter/tool implementation, output JSON and Sanity revision. Any change
requires reevaluation. Preserve `evaluation.json` and the delivery journal.
Evaluation requires REAPER to freshly load its own temporary tab. Close an open
`BUILD/AUTOPLAY.RPP` tab before running evaluation after a rebuild; a clean older
tab is deliberately refused as saved-file evidence and is left untouched.

## Remote delivery contract

Add `project_id`, `dataset` and `api_version` to the manifest's `sanity` identity.
The `delivery` object contains `storage_url`, the current score-slug `bucket`, and
nonempty user-facing `changes`. Each section has one explicit default click
`storage_path`: `<movementIndex>/CLICKDATA/<filename>.json`. Flutter scales this
one default file to the selected tempo; this tool does not create per-tempo JSON.

Credentials are read from an explicit plist, then an explicit dotenv, then the
process environment. Sanity reads use `SANITY_READ_TOKEN` or `SANITY_WRITE_TOKEN`;
publication requires `SANITY_WRITE_TOKEN`. Storage uses `SUPABASE_URL`,
`SUPABASE_KEY` (or `SUPABASE_ANON_KEY`) and `SUPABASE_ACCESS_TOKEN`. A server-side
service-role environment configuration is also supported. `SUPABASE_URL` must
match the manifest endpoint. HTTP errors never include credential-bearing bodies.

Preview downloads current click objects and shows exact before/after hashes.
Apply acquires a create-only cooperative Storage writer lock, rechecks the plan,
backs up replaced bytes locally, uploads and verifies authenticated origin reads,
then publishes section duration/handoff metadata, `updateRequired` and one
changelog entry in a revision-guarded Sanity mutation. Unrelated score fields are
verified unchanged. CLICKDATA is excluded from the audio-only manifest.

No Storage/Sanity cross-service transaction exists. Other upload tools must not
write these objects during delivery. A lock serializes this pipeline's publishers;
it cannot enforce exclusion against arbitrary external writers. A process crash
can leave `.gphil-autoplay-locks/<score-id>.json`; inspect its owner and journal
before an administrator removes it. Ordinary failures release the lock, preserve
the journal and can resume after rechecking remote state. Uncertain metadata
publication is reconciled by exact expected content before any retry.

Existing Sanity drafts cause refusal; preserve them and use the established
review workflow. The tool never creates a new score or changes score visibility.
Uploads are not a live app cache-refresh test. Check the private test score's
regular update/session reload before claiming app playback qualification.

## Real examples

See `examples/autoplay/catalog.json` and `examples/autoplay/README.md`.
The four requested works exercise normal preparation across different projects;
Grieg is deliberately a legacy-conflict/recovery example. Captured Sanity
snapshots are dated evidence, not perpetual permission to publish against their
old revisions. Preparation reports unresolved facts rather than auto-approving
old metadata or reusing an earlier agent's guesses.

## Reproduce native qualification

With the normal REAPER instance running and the bridge available:

```sh
python3 tools/qualify_autoplay.py --output /absolute/new/qualification-directory
```

This runs four synthetic qualification cases:
1. Two invented 2/4 silent-audio hold candidates changing one last-beat hold
   from two beats to three, checking the expected 600 ms shift of the following
   section against native exports and evaluating both candidates.
2. A third candidate recovering an intentionally bad legacy pattern through a
   reviewed data override, with a between-beat reset at 0.75 seconds.
3. A fourth candidate (`mp3-gapless`) using real LAME-encoded transient MP3
   media to verify the text-level writer/auditor guard (`FILE "<path>" 1`
   emitted, mutated `FILE "<path>" 0` rejected by `audit_rpp_integrity`, and
   native beat-grid evaluation passing). Note that this is a text-level and
   beat-grid check—it does not read back REAPER's decoded MP3 PCM audio.

Its explicit discrepancy approvals belong only to these synthetic fixtures. It
cannot publish and grants no approval to real music. Existing output directories
are preserved; use a new path for each run.

The live 2026-11-19 run on REAPER 7.86/macOS-arm64 passed the rebuilt candidates.
Separate native fixtures passed ordinary 4/4, a fractional-start 6/8 pickup and a
partial-measure reset. These checks cover native timing and file generation;
rendered-click sound and live app playback remain separate qualification steps.
