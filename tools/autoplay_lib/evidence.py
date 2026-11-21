"""Immutable input identity and decoded sample duration."""

import hashlib
import json
import subprocess
from pathlib import Path


def digest(path):
    with open(path, "rb") as stream:
        h = hashlib.sha256()
        for block in iter(lambda: stream.read(1 << 20), b""):
            h.update(block)
        return h.hexdigest()


def duration(path):
    data = json.loads(
        subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_streams", "-of", "json", str(path)]
        )
    )
    streams = [s for s in data["streams"] if s["codec_type"] == "audio"]
    if len(streams) != 1:
        raise ValueError(f"Ambiguous audio streams in {path}")
    rate = int(streams[0]["sample_rate"])
    args = [
        "ffmpeg",
        "-nostdin",
        "-xerror",
        "-v",
        "error",
        "-i",
        str(path),
        "-map",
        "0:a:0",
        "-ac",
        "1",
        "-f",
        "s16le",
        "-",
    ]
    count = 0
    with subprocess.Popen(args, stdout=subprocess.PIPE) as process:
        for block in iter(lambda: process.stdout.read(1 << 20), b""):
            count += len(block)
        if process.wait() or not count:
            raise ValueError(f"Cannot decode {path}")
    return count / (2 * rate)


def resolve(manifest, path):
    return (Path(manifest["project_root"]) / path).resolve()


def input_fingerprints(manifest):
    return {str(resolve(manifest, p)): h for p, h in manifest["fingerprints"].items()}
