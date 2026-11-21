"""Small file and identity primitives shared by AUTOPLAY commands."""
import hashlib
import json
import os
from pathlib import Path
import tempfile


def digest_bytes(data):
    return hashlib.sha256(data).hexdigest()


def file_digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def json_bytes(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + '\n').encode()


def identity(value):
    return digest_bytes(json_bytes(value))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='.' + path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(json_bytes(value))
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def tool_fingerprints():
    root = Path(__file__).resolve().parents[2]
    paths = list((root / 'tools/autoplay_lib').glob('*.py'))
    paths += [root / 'tools/autoplay.py', root / 'tools/reaper_bridge.py']
    paths += list((root / 'lib').glob('native_*.lua'))
    return {str(p): file_digest(p) for p in sorted(paths) if p.exists()}


def check_fingerprints(values):
    changed = [str(p) for p, expected in values.items()
               if not Path(p).is_file() or file_digest(p) != expected]
    if changed:
        raise ValueError('Checked inputs changed: ' + ', '.join(changed))
