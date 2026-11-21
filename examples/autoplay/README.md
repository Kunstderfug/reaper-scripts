# AUTOPLAY preparation examples

`catalog.json` identifies actual source movements for Tchaikovsky Piano Concerto
No. 1, Rachmaninoff Piano Concerto No. 1, Beethoven Piano Concertos Nos. 1 and 3,
and Grieg. Grieg deliberately tests conflicting legacy evidence; none of the
other works is assumed to be correct without checking.

The read-only Sanity snapshots in `evidence/` were collected on 2026-11-19. They
contain section identity and timing observations, with no credentials. A current
canonical snapshot and revision are required before any delivery.

```sh
python3 tools/prepare_autoplay_examples.py \
  --project-root /Volumes/PROJECTS/PROJECTS_IN_WORK/REAPER_PROJECTS/G-PHIL \
  --template '/Users/slav/Library/Application Support/REAPER/ProjectTemplates/GPHIL_AUTOPLAY.RPP' \
  --output /absolute/new/example-evidence
```

Each movement gets `movement.json` and `questions.json`. Existing manifests are
preserved. Preparation never approves a render scale, pickup, fermata, solo count
or handoff. Unsupported source metadata is a question, not a reason to infer a
filename tempo or silently simplify a click pattern.

Native source-timeline checks on 2026-11-19 used temporary trackless copies with
the original tempo/meter and exact region bounds. Independent Python integration
matched all exported events (within 1 ms and with identical beat labels):

| First movement | Regions | Native clicks | Result |
| --- | ---: | ---: | --- |
| Tchaikovsky 1 | 36 | 2,075 | Matched |
| Beethoven 1 | 26 | 1,973 | Matched |
| Beethoven 3 | 18 | 1,881 | Matched |
| Rachmaninoff 1 | 25 | — | Coincident source tempo events require review |

The collector also matched all 105 sections in those four first movements to
Sanity keys, default-tempo orchestra files and OPUS references. Matching identity
does not establish actual render speed or audible alignment. Those mappings stay
unapproved until evidence has been checked.

Full preparation produced 14 manifests with 289 sections and 678 review entries.
These include routine mapping approvals as well as source timing conflicts:

| Work | Movements prepared | Sections | Source timing blockers |
| --- | ---: | ---: | --- |
| Tchaikovsky 1 | I–III | 76 | None in the supported parser |
| Rachmaninoff 1 | I–III | 56 | I: coincident tempo events; II–III: unmodeled metadata |
| Beethoven 1 | I–III | 68 | II–III: unmodeled metadata/patterns |
| Beethoven 3 | I–II | 26 | None in the supported parser |
| Grieg | I–III | 63 | Unmodeled legacy metadata/patterns in all three |

The eight movements with timing blockers retain exact raw lines and source-line
numbers. Clearing their question list does not bypass compilation's independent
source check. The other six still need actual musical/mapping approvals.

For a complete, reproducible synthetic build and native evaluation, run
`tools/qualify_autoplay.py --output /absolute/new/qualification-directory`.
Its first two projects demonstrate a last beat of 2/4 lasting two versus three beats:
the next section starts at 3.000 versus 3.600 seconds. They include rate-1
orchestra items, a native REAPER click-source lane and a muted OPUS reference
lane. A third project demonstrates a reviewed legacy timing replacement and a
between-beat reset at 0.75 seconds. All three passed native export and evaluation
on REAPER 7.86/macOS-arm64. They are test data, not a production score or musical
approval. The comparison checks and all delivery tests use local fixtures;
actual Storage/Sanity publication and app playback are not qualified here.

See [the workflow](../../docs/autoplay-pipeline.md) for decisions, evaluation,
credentials and explicit publication.
