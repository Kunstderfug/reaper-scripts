"""Collect original project evidence without guessing editorial decisions."""

import json
import shlex
from math import isfinite
from pathlib import Path

from .evidence import digest, resolve
from .support import identity
from .tempo import Grid


def _tempo_point(line):
    _, t, b, shape, *tail = shlex.split(line)
    time, bpm, shape = float(t), float(b), int(shape)
    if not isfinite(time) or time < 0 or not isfinite(bpm) or bpm <= 0:
        raise ValueError(f"Invalid tempo time or BPM at {t}")
    if shape not in (0, 1):
        raise ValueError(f"Unsupported tempo shape at {t}")
    point = {"time": time, "bpm": bpm, "shape": shape}
    if not tail:
        return point, None
    point["tail"] = tail
    if (
        len(tail) > 9
        or tail[1:2] not in ([], ["0"], ["1"], ["5"])
        or tail[2:3] not in ([], ["1"], ["9"])
        or any(x not in ("0", "0.0", "") for x in [*tail[3:6], *tail[7:8]])
    ):
        raise ValueError(f"Unsupported tempo metadata at {t}: {tail}")
    packed = int(tail[0])
    n, d = packed & 65535, packed >> 16
    if packed and (not n or d not in (1, 2, 4, 8, 16, 32, 64)):
        raise ValueError(f"Unsupported click pattern or meter at {t}")
    if len(tail) > 8 and (not packed or tail[8] != "A" + "B" * (n - 1)):
        raise ValueError(f"Unsupported click pattern or meter at {t}")
    # Nonzero pattern codes supported by the observed default-pattern pairs.
    patterns = {2: "9", 3: "41", 4: "169", 6: "2729"}
    if (
        len(tail) > 6
        and tail[6] != "0"
        and (len(tail) != 9 or tail[6] != patterns.get(n))
    ):
        raise ValueError(f"Unsupported encoded click pattern at {t}")
    meter = {"time": time, "numerator": n, "denominator": d, "tail": tail}
    return point, meter if packed else None


def _source_inventory(path):
    stack, regions, points, meters = [], {}, [], []
    raw, issues = [], []
    previous = None
    initial = None
    for number, line in enumerate(
        Path(path).read_text(encoding="utf-8-sig").splitlines(), 1
    ):
        s = line.strip()
        if s.startswith("<"):
            stack.append(s.split()[0][1:])
        elif s == ">":
            stack.pop()
        elif stack == ["REAPER_PROJECT"] and s.startswith("TEMPO "):
            raw.append(s)
            try:
                _, b, n, d, *tail = s.split()
                if tail not in ([], ["0"]):
                    raise ValueError("Unsupported initial tempo metadata")
                initial = float(b), int(n), int(d)
                if (
                    not isfinite(initial[0])
                    or initial[0] <= 0
                    or initial[1] <= 0
                    or initial[2] not in (1, 2, 4, 8, 16, 32, 64)
                ):
                    raise ValueError("Unsupported initial tempo or meter")
            except ValueError as error:
                issues.append(
                    {
                        "field": "source_tempo_points",
                        "line": number,
                        "raw": s,
                        "message": str(error),
                    }
                )
        elif stack == ["REAPER_PROJECT"] and s.startswith("MARKER "):
            _, k, t, name, flags, *_ = shlex.split(s)
            if int(flags) & 1:
                regions.setdefault(k, []).append((float(t), name))
        elif stack == ["REAPER_PROJECT", "TEMPOENVEX"] and s.startswith("PT "):
            raw.append(s)
            try:
                point, meter = _tempo_point(s)
                t = point["time"]
                if previous is not None and t <= previous:
                    raise ValueError(
                        f"Coincident or out-of-order tempo timestamp at {t}"
                    )
                previous = t
                points.append(point)
                if meter:
                    meters.append(meter)
            except ValueError as error:
                issues.append(
                    {
                        "field": "source_tempo_points",
                        "line": number,
                        "raw": s,
                        "message": str(error),
                    }
                )
    if (not initial and not issues) or stack:
        raise ValueError("Incomplete source RPP")
    if not issues and (not points or points[0]["time"] > 0):
        points.insert(0, {"time": 0.0, "bpm": initial[0], "shape": 1})
    if not issues and (not meters or meters[0]["time"] > 0):
        meters.insert(
            0, {"time": 0.0, "numerator": initial[1], "denominator": initial[2]}
        )
    sections = []
    for k, pair in regions.items():
        if len(pair) != 2 or pair[1][0] <= pair[0][0] or pair[1][1]:
            raise ValueError(f"Ambiguous region {k}")
        (start, name), (end, _) = pair
        sections.append(
            {
                "key": k,
                "name": name,
                "region_name": name,
                "source_start_seconds": start,
                "source_end_seconds": end,
                "scale": 1.0,
                "audio_path": None,
                "opus_path": None,
                "decision": {},
                "handoff_seconds": None,
            }
        )
    sections.sort(key=lambda s: s["source_start_seconds"])
    if issues:
        return (
            [],
            [],
            sections,
            {"source_timing_issues": issues, "raw_source_timing": raw},
        )
    return points, meters, sections, {}


def source_data(path):
    points, meters, sections, evidence = _source_inventory(path)
    if evidence:
        raise ValueError(evidence["source_timing_issues"][0]["message"])
    return points, meters, sections


def movement_identity(score, movement_key):
    movements = [v for v in score["movements"] if v["_key"] == movement_key]
    if len(movements) != 1:
        raise ValueError(f"Expected one Sanity movement {movement_key}")
    movement = movements[0]
    index, prefix = movement["index"], score["pathName"]
    metadata = {
        "score_id": score["_id"],
        "revision": score["_rev"],
        "movement_key": movement_key,
        "movement_index": index,
        "path_name": prefix,
        "slug": score["slug"]["current"],
    }
    return movement, metadata


def verify_observations(manifest):
    path = Path(manifest["project_root"]) / manifest["sanity_snapshot_path"]
    movement, metadata = movement_identity(
        json.loads(path.read_text()), manifest["movement_key"]
    )
    sections = manifest["sections"]
    if (
        any(manifest["sanity"].get(k) != v for k, v in metadata.items())
        or [s["sanity"] for s in sections] != movement["sections"]
    ):
        raise ValueError(
            "Sanity identity, order or observations differ from pinned snapshot"
        )
    for section in sections:
        obs = section["sanity"]
        stem = f"{metadata['path_name']}_{movement['index']}_{obs['name']}_{obs['defaultTempo']:g}"
        if (
            section["key"] != obs["_key"]
            or section["name"] != obs["name"]
            or section["region_name"] != stem
            or section["storage_path"] != f"{movement['index']}/CLICKDATA/{stem}.json"
        ):
            raise ValueError("Section identity differs from pinned Sanity record")


def prepare_manifest(
    source_path,
    template_path,
    sanity_snapshot_path,
    movement_key,
    project_root,
    **options,
):
    root = Path(project_root).resolve()

    def relative(p):
        p = (root / p).resolve()
        return str(p.relative_to(root)) if p.is_relative_to(root) else str(p)

    paths = [relative(p) for p in (source_path, template_path, sanity_snapshot_path)]
    points, meters, sections, timing = _source_inventory(root / paths[0])
    score = json.loads((root / paths[2]).read_text())
    movement, metadata = movement_identity(score, movement_key)
    index, prefix = movement["index"], score["pathName"]
    folder = root / paths[0]
    media = root / options.get(
        "media_dir", options.get("media_directory", folder.parent)
    )
    audio_dir = media if media.name == "AUDIO" else media / "AUDIO"
    clicks = audio_dir.parent / "CLICKDATA"
    observations = movement["sections"]
    selected = set(paths)
    if len({s["name"] for s in observations}) != len(observations) or len(
        {s["_key"] for s in observations}
    ) != len(observations):
        raise ValueError("Duplicate Sanity section name or key")
    joined = []
    for obs in observations:
        matches = [s for s in sections if s["name"] == obs["name"]]
        if len(matches) != 1:
            raise ValueError(f"Ambiguous or absent source region {obs['name']}")
        sec = matches[0].copy()
        tempo = obs["defaultTempo"]
        stem = f"{prefix}_{index}_{obs['name']}_{tempo:g}"
        candidates = sorted(
            p
            for p in (audio_dir / obs["name"]).glob(stem + ".*")
            if p.suffix.lower() in (".wav", ".flac", ".mp3", ".ogg", ".aif", ".aiff")
        )
        opus = clicks / (stem + ".opus")
        preferred = next(
            (
                p
                for ext in (".flac", ".wav", ".aif", ".aiff", ".ogg", ".mp3")
                for p in candidates
                if p.suffix.lower() == ext
            ),
            None,
        )
        sec.update(
            region_name=stem,
            source_region_id=sec["key"],
            key=obs["_key"],
            sanity=obs,
            audio_candidates=list(map(relative, candidates)),
            audio_path=relative(preferred) if preferred else None,
            opus_path=relative(opus) if opus.is_file() else None,
            comparison={"offset_ms": 0, "time_scale": 1.0, "tolerance_ms": 3},
            storage_path=f"{index}/CLICKDATA/{stem}.json",
        )
        for key in ("audio_path", "opus_path"):
            if sec[key]:
                selected.add(sec[key])
        joined.append(sec)
    return {
        "version": 1,
        "project_root": str(root),
        "movement_key": movement_key,
        "sanity": metadata,
        "source_path": paths[0],
        "template_path": paths[1],
        "sanity_snapshot_path": paths[2],
        "fingerprints": {p: digest(root / p) for p in sorted(selected)},
        "sections": joined,
        **timing,
        "source_tempo_points": points,
        "source_meter_anchors": meters,
    }


def timing_review_sha256(manifest):
    """Digest of the exact replacement and immutable inputs seen by the reviewer."""
    override = manifest["source_timing_override"]
    paths = (manifest["source_path"], override["evidence"])
    return identity(
        {
            "reviewer": override["reviewer"],
            "source_path": paths[0],
            "evidence": paths[1],
            "fingerprints": {p: manifest["fingerprints"][p] for p in paths},
            "points": override["points"],
            "meter_anchors": override["meter_anchors"],
        }
    )


def _validate_replacement(override, sections):
    if override.keys() - {
        "points",
        "meter_anchors",
        "approved",
        "approved_sha256",
        "reviewer",
        "evidence",
    }:
        raise ValueError("Unexpected source timing override fields")
    end = max((s["source_end_seconds"] for s in sections), default=0)
    for field, keys in (
        ("points", {"time", "bpm", "shape"}),
        ("meter_anchors", {"time", "numerator", "denominator"}),
    ):
        rows = override.get(field)
        if not isinstance(rows, list) or not rows:
            raise ValueError(f"Expected nonempty override {field}")
        previous = -1
        optional = {"reset"} if field == "meter_anchors" else set()
        for row in rows:
            if not isinstance(row, dict) or set(row) - optional != keys:
                raise ValueError(f"Invalid override {field} fields")
            t = row["time"]
            if (
                type(t) not in (float, int)
                or not 0 <= t <= end
                or t <= previous
                or (previous == -1 and t != 0)
            ):
                raise ValueError(
                    f"Override {field} times must increase from zero within source regions"
                )
            previous = t
            if field == "points":
                if (
                    type(row["bpm"]) not in (float, int)
                    or type(row["shape"]) is not int
                ):
                    raise ValueError("Invalid override tempo point")
            elif (
                type(row.get("reset", False)) is not bool
                or type(row["numerator"]) is not int
                or not 1 <= row["numerator"] <= 65535
                or type(row["denominator"]) is not int
                or row["denominator"] not in (1, 2, 4, 8, 16, 32, 64)
            ):
                raise ValueError("Invalid override meter")
    grid = Grid(override["points"])
    times = set(grid.times)
    if any(m["time"] not in times for m in override["meter_anchors"]):
        raise ValueError("Override meter anchors require matching tempo points")


def partial_reset_approved(decision, fingerprints):
    return (
        isinstance(decision, dict)
        and decision.get("policy") == "reset"
        and decision.get("approved") is True
        and isinstance(decision.get("reviewer"), str)
        and decision["reviewer"].strip() != ""
        and isinstance(decision.get("evidence"), str)
        and decision["evidence"] in fingerprints
    )


def _replacement_meters(manifest, anchors):
    meters = []
    for anchor in anchors:
        meter = anchor.copy()
        if meter.pop("reset", False):
            if not partial_reset_approved(
                manifest.get("partial_measure_decision"), manifest["fingerprints"]
            ):
                raise ValueError(
                    f"Partial measure at {meter['time']} needs approved reset"
                )
            packed = meter["denominator"] * 65536 + meter["numerator"]
            meter["tail"] = [str(packed), "5"]
        meters.append(meter)
    return meters


def _effective_timing(manifest):
    issues = list(manifest.get("source_timing_issues", []))
    if "source_timing_override" not in manifest:
        return manifest["source_tempo_points"], manifest["source_meter_anchors"], issues
    override = manifest["source_timing_override"]
    try:
        if not issues or not manifest.get("raw_source_timing"):
            raise ValueError("Timing override requires unresolved raw source evidence")
        if not isinstance(override, dict):
            raise ValueError("Expected source timing override object")
        _validate_replacement(override, manifest["sections"])
        reviewer, evidence = override.get("reviewer"), override.get("evidence")
        if not (
            override.get("approved") is True
            and isinstance(reviewer, str)
            and reviewer.strip()
            and isinstance(evidence, str)
            and evidence in manifest["fingerprints"]
            and manifest["source_path"] in manifest["fingerprints"]
        ):
            raise ValueError(
                "Approve timing override with reviewer and pinned evidence"
            )
        if override.get("approved_sha256") != timing_review_sha256(manifest):
            raise ValueError(
                "Timing override approval differs from reviewed grid or pinned evidence"
            )
        meters = _replacement_meters(manifest, override["meter_anchors"])
    except (ValueError, OverflowError) as error:
        issues.append({"field": "source_timing_override", "message": str(error)})
        return [], [], issues
    return override["points"], meters, []


def _verify_source(manifest):
    points, meters, original, timing = _source_inventory(
        resolve(manifest, manifest["source_path"])
    )
    if any(
        timing.get(k) != manifest.get(k)
        for k in ("raw_source_timing", "source_timing_issues")
    ):
        raise ValueError("Source timing evidence differs from pinned RPP")
    if (
        points != manifest["source_tempo_points"]
        or meters != manifest["source_meter_anchors"]
    ):
        raise ValueError("Source grid differs from pinned RPP")
    originals = {s["key"]: s for s in original}
    sections = manifest["sections"]
    if len({s["key"] for s in sections}) != len(sections):
        raise ValueError("Duplicate section keys")
    for s in sections:
        orig = originals.get(s["source_region_id"])
        if not orig or any(
            s[k] != orig[k]
            for k in ("source_start_seconds", "source_end_seconds", "name")
        ):
            raise ValueError("Region differs from pinned source")


def _verified_manifest(manifest):
    if type(manifest.get("version")) is not int or manifest["version"] != 1:
        raise ValueError("Unsupported manifest version")
    for p, h in manifest["fingerprints"].items():
        if digest(resolve(manifest, p)) != h:
            raise ValueError(f"Evidence changed: {p}")
    verify_observations(manifest)
    _verify_source(manifest)
    points, meters, issues = _effective_timing(manifest)
    return points, meters, issues + _section_questions(manifest)


def questions(manifest):
    return _effective_timing(manifest)[2] + _section_questions(manifest)


def _section_questions(manifest):
    result = []
    for k in ("source_path", "template_path", "sanity_snapshot_path"):
        if manifest[k] not in manifest["fingerprints"]:
            result.append({"field": k, "message": "Missing pinned input"})
    for s in manifest["sections"]:
        d = s.get("decision", {})
        missing_basis = s["sanity"].get("autoContinueMarker") is None or d.get(
            "handoff_basis"
        ) not in ("render", "source")
        if (
            s["sanity"].get("autoContinue")
            and s.get("handoff_seconds") is None
            and missing_basis
        ):
            result.append(
                {
                    "section": s["key"],
                    "field": "handoff_seconds",
                    "message": "Review handoff and time basis",
                }
            )
        if s.get("click_exceptions"):
            result.append(
                {
                    "section": s["key"],
                    "field": "click_exceptions",
                    "message": "Custom pulses require rendered qualification",
                }
            )
        if s.get("opus_path") and Path(s["opus_path"]).suffix.lower() != ".opus":
            result.append(
                {
                    "section": s["key"],
                    "field": "opus_path",
                    "message": "Select original OPUS reference",
                }
            )
        for field in ("audio_path", "opus_path"):
            if s.get(field) not in manifest["fingerprints"]:
                result.append(
                    {
                        "section": s["key"],
                        "field": field,
                        "message": "Select pinned media",
                    }
                )
        if (
            s.get("audio_path")
            and d.get("approved") is True
            and (
                d.get("source_to_render_scale") != s["scale"]
                or d.get("audio_sha256")
                != manifest["fingerprints"].get(s["audio_path"])
            )
        ):
            result.append(
                {
                    "section": s["key"],
                    "field": "scale",
                    "message": "Confirm source-to-render scale against selected recording",
                }
            )
        if not (
            d.get("approved") is True
            and d.get("reviewer")
            and d.get("evidence") in manifest["fingerprints"]
        ):
            result.append(
                {
                    "section": s["key"],
                    "field": "decision",
                    "message": "Approve mapping with pinned evidence",
                }
            )
    return result


def load_manifest(path, project_root=None, require_approved=False):
    m = json.loads(Path(path).read_text())
    if project_root:
        m["project_root"] = str(Path(project_root).resolve())
    _, _, issues = _verified_manifest(m)
    if require_approved and issues:
        raise ValueError(str(issues))
    return m
