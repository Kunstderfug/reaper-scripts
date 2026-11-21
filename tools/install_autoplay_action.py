#!/usr/bin/env python3
"""Deploy the AUTOPLAY action and native bridge into an existing REAPER resource directory."""
import argparse
import hashlib
from pathlib import Path
import shutil
import sys


def install(resource):
    root = Path(__file__).resolve().parents[1]
    target = resource / 'Scripts/GPhil'
    files = ['GPhil_autoplay_pipeline.lua', 'GPhil_nativeBridge_start.lua',
             'lib/native_bridge.lua', 'lib/native_click_export.lua', 'lib/native_bridge_protocol.lua']
    if not resource.is_dir():
        raise ValueError('REAPER resource directory does not exist')
    for name in files:
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, destination)
        if hashlib.sha256(destination.read_bytes()).digest() != hashlib.sha256((root / name).read_bytes()).digest():
            raise ValueError('Deployment verification failed: ' + name)
    (target / 'autoplay_pipeline.repo').write_text(str(root) + '\n')
    (target / 'autoplay_pipeline.python').write_text(sys.executable + '\n')
    # Apps launched from Applications need not inherit Homebrew's shell PATH.
    media_bins = []
    for command in ('ffmpeg', 'ffprobe'):
        executable = shutil.which(command)
        if not executable:
            raise ValueError('Install ' + command + ' before installing the action')
        folder = str(Path(executable).parent)
        if folder not in media_bins:
            media_bins.append(folder)
    (target / 'autoplay_pipeline.path').write_text(':'.join(
        media_bins + ['/usr/bin', '/bin', '/usr/sbin', '/sbin']) + '\n')
    return target / files[0]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--resource', type=Path,
                        default=Path.home() / 'Library/Application Support/REAPER')
    print(install(parser.parse_args().resource))
