"""Patch direct children of a routing template, preserving other chunks."""

import fcntl
import hashlib
import json
import os
import shlex
import tempfile
import uuid
from pathlib import Path

from .evidence import digest, duration, resolve
from .timeline import compile_manifest


def children(lines):
    i = 1
    while i < len(lines) - 1:
        start = i
        depth = int(lines[i].lstrip().startswith("<"))
        i += 1
        while depth:
            line = lines[i].strip()
            depth += int(line.startswith("<")) - int(line == ">")
            i += 1
        yield lines[start:i]


def quote(value):
    if any(c in str(value) for c in '"\r\n'):
        raise ValueError("Unsupported RPP string delimiter")
    return '"' + str(value) + '"'


def guid(key):
    return "{" + str(uuid.uuid5(uuid.NAMESPACE_URL, key)).upper() + "}"


def item(s, role):
    path = s["opus_path"] if role == "opus" else s["audio_path"]
    length = s["audio_duration_seconds"]
    if role == "opus":
        length = duration(path)
    if role == "click":
        length = s["end_seconds"] - s["start_seconds"]
        src = [
            "      <SOURCE CLICK",
            "        AUTO 1 0",
            "        VOL 0.5 0.25",
            "        BEATLEN 4",
            "        FREQ 1760 880 1",
            "        MULT 1",
            "      >",
        ]
    else:
        suffix = Path(path).suffix.lower()
        formats = {
            ".wav": "WAVE",
            ".aif": "WAVE",
            ".aiff": "WAVE",
            ".flac": "FLAC",
            ".opus": "OPUS",
            ".ogg": "VORBIS",
            ".mp3": "MP3",
        }
        source = formats[suffix]
        # REAPER's PCM_source_mp3 requires trailing "1" to strip Xing/LAME
        # encoder+decoder padding (~47 ms at 48 kHz); omitting it falls back to
        # legacy mode (0) and leaves MP3 audio late relative to clicks.
        file_line = "        FILE " + quote(path) + (" 1" if source == "MP3" else "")
        src = ["      <SOURCE " + source, file_line, "      >"]
    return [
        "    <ITEM",
        f"      POSITION {s['start_seconds']}",
        f"      LENGTH {length}",
        "      LOOP 1" if role == "click" else "      LOOP 0",
        "      BEAT -1" if role == "click" else "      BEAT 0",
        "      IGUID " + guid(role + s["key"]),
        "      GUID " + guid("take:" + role + s["key"]),
        "      NAME " + quote(s["region_name"]),
        "      SOFFS 0",
        "      PLAYRATE 1 1 0 -1 0 0.0025",
        *src,
        "    >",
    ]


def write_project(manifest, plan, output_path):
    if plan != compile_manifest(manifest) or plan["issues"]:
        raise ValueError("Unresolved decisions or stale plan")
    out = Path(output_path).resolve()
    if out in {resolve(manifest, p) for p in manifest["fingerprints"]}:
        raise ValueError("Output collides with a pinned input")
    receipt = out.with_suffix(out.suffix + ".receipt.json")
    names = manifest.get(
        "track_names",
        {
            "orchestra_1": "Orchestra 1",
            "orchestra_2": "Orchestra 2",
            "click": "Click",
            "opus": "OPUS",
        },
    )
    if len(set(names.values())) != 4:
        raise ValueError("Four distinct routing template tracks required")
    template = resolve(manifest, manifest["template_path"]).read_text().splitlines()
    track_chunks = [c for c in children(template) if c[0].strip().startswith("<TRACK ")]

    def track_name(chunk):
        return next(
            (
                shlex.split(p[0])[1]
                for p in children(chunk)
                if p[0].strip().startswith("NAME ")
            ),
            "",
        )

    standard = "track_names" not in manifest and [
        track_name(c) for c in track_chunks
    ] == ["", "", "CLICKS"]
    track_index = 0
    lines = [template[0], "  TIMELOCKMODE 1"]
    envelope_settings = []
    first = plan["meter_anchors"][0]
    lines.append(
        f"  TEMPO {plan['tempo_points'][0]['bpm']:.17g} {first['numerator']} {first['denominator']} 0"
    )
    matched = set()
    for chunk in children(template):
        tag = chunk[0].strip().split()[0]
        if tag == "<TEMPOENVEX":
            for part in children(chunk):
                if not part[0].strip().startswith("PT "):
                    envelope_settings.extend(part)
        if tag == "TEMPO":
            continue
        if tag in ("TIMELOCKMODE", "MARKER", "<TEMPOENVEX"):
            continue
        if tag == "<TRACK":
            parts = list(children(chunk))
            name = next(
                (
                    shlex.split(p[0])[1]
                    for p in parts
                    if p[0].strip().startswith("NAME ")
                ),
                "",
            )
            role = next((k for k, v in names.items() if v == name), None)
            if standard:
                role = ("orchestra_1", "orchestra_2", "click")[track_index]
            track_index += 1
            if role:
                if role in matched:
                    raise ValueError("Ambiguous template track " + name)
                matched.add(role)
                lines.append(chunk[0])
                for part in parts:
                    if standard and part[0].strip().startswith("NAME "):
                        lines.append("    NAME " + quote(names[role]))
                        continue
                    if role in ("click", "opus") and part[0].strip().startswith(
                        "MUTESOLO "
                    ):
                        flags = part[0].split()
                        flags[1:3] = ["1" if role == "opus" else "0", "0"]
                        lines.append("    " + " ".join(flags))
                        continue
                    if part[0].strip().split()[0] not in ("<ITEM", "BEAT"):
                        lines.extend(part)
                lines.append("    BEAT -1" if role == "click" else "    BEAT 0")
                if role == "click" and plan["sections"]:
                    last = max(s["end_seconds"] for s in plan["sections"])
                    lines.extend(
                        item(
                            dict(
                                plan["sections"][0], start_seconds=0.0, end_seconds=last
                            ),
                            "click",
                        )
                    )
                for s in plan["sections"]:
                    if role == "opus" or role == "orchestra_" + str(s["lane"] + 1):
                        lines.extend(
                            item(
                                s, "orchestra" if role.startswith("orchestra") else role
                            )
                        )
                lines.append(chunk[-1])
                continue
        lines.extend(chunk)
    if standard:
        matched.add("opus")
        lines.extend(
            [
                "  <TRACK " + guid("opus track"),
                '    NAME "OPUS reference"',
                "    MUTESOLO 1 0 0",
                "    BEAT 0",
            ]
        )
        for section in plan["sections"]:
            lines.extend(item(section, "opus"))
        lines.append("  >")
    if matched != set(names):
        raise ValueError(
            "Missing routing template tracks: " + str(set(names) - matched)
        )
    lines.append("  <TEMPOENVEX")
    lines.extend(envelope_settings)
    meters = {m["time"]: m for m in plan["meter_anchors"]}
    for p in plan["tempo_points"]:
        tail = (" " + " ".join(x or '""' for x in p["tail"])) if p.get("tail") else ""
        if p["time"] in meters:
            m = meters[p["time"]]
            fields = m.get("tail", [str(m["denominator"] * 65536 + m["numerator"])])
            tail = " " + " ".join(x or '""' for x in fields)
        lines.append(f"    PT {p['time']:.17g} {p['bpm']:.17g} {p['shape']}{tail}")
    lines.append("  >")
    for i, s in enumerate(plan["sections"], 1):
        if s["handoff_seconds"] is not None:
            lines.append(f"  MARKER {i} {s['handoff_seconds']} {quote('auto')} 0 0 1 B")
        lines.extend(
            [
                f"  MARKER {i} {s['start_seconds']} {quote(s['region_name'])} 1 0 1 B",
                f'  MARKER {i} {s["end_seconds"]} "" 1',
            ]
        )
    lines.append(template[-1])
    out.parent.mkdir(parents=True, exist_ok=True)

    def atomic(path, data):
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
            f.write(data.encode())
        os.replace(f.name, path)

    data = "\n".join(lines) + "\n"
    fingerprint = hashlib.sha256(data.encode()).hexdigest()
    report = {
        "output_path": str(out),
        "sha256": fingerprint,
        "receipt_path": str(receipt),
    }
    descriptor = os.open(out.parent, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        old = digest(out) if out.exists() else None
        if old:
            recorded = json.loads(receipt.read_text()) if receipt.exists() else {}
            if recorded.get("output_path") != str(out) or old not in (
                recorded.get("sha256"),
                recorded.get("previous_sha256"),
            ):
                raise ValueError("Existing output has no matching build receipt")
        atomic(
            receipt,
            json.dumps(dict(report, previous_sha256=old), sort_keys=True) + "\n",
        )
        atomic(out, data)
        atomic(receipt, json.dumps(report, sort_keys=True) + "\n")
    finally:
        os.close(descriptor)
    return report
