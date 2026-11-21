#!/usr/bin/env python3
"""Request native API exports from the already-running GPhil REAPER bridge."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
from urllib.parse import quote
import uuid

DEFAULT_MAILBOX = Path.home() / 'Library/Application Support/REAPER/GPhilBridge'


def request(mailbox, command, fields, timeout):
    status = json.loads((mailbox / 'status.json').read_text())
    if status['state'] != 'running' or abs(time.time() - status['heartbeat']) > 5:
        raise RuntimeError('REAPER bridge is stopped or unresponsive. Run GPhil_nativeBridge_start.lua in REAPER.')
    identifier = uuid.uuid4().hex
    values = dict(version='1', session=status['session'], expires=str(int(time.time() + timeout)),
                  command=command, **fields)
    inbox = mailbox / 'inbox' / (identifier + '.request')
    response = mailbox / 'responses' / (identifier + '.json')
    temp = inbox.with_suffix('.tmp')
    with temp.open('x') as stream:
        os.chmod(temp, 0o600)
        stream.write(''.join(f'{key}={quote(str(value), safe="")}\n' for key, value in values.items()))
    temp.replace(inbox)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if response.exists():
            result = json.loads(response.read_text())
            if result.get('session') != status['session'] or result.get('id') != identifier:
                raise RuntimeError('Bridge response identity mismatch')
            response.unlink()
            return result
        time.sleep(0.05)
    inbox.unlink(missing_ok=True)
    raise RuntimeError(f'Bridge request timed out ({identifier}); an export already running may still finish. Check output before retrying.')


def verify_saved_only(result, project):
    """Defense in depth: a saved-only receipt must prove an exact, clean, unchanged saved tab."""
    receipt = result.get('result') or {}
    problems = []
    if receipt.get('savedOnly') is not True:
        problems.append('bridge did not honour saved_only (older bridge loaded? restart the bridge)')
    if receipt.get('project') != project:
        problems.append(f"receipt project {receipt.get('project')!r} != {project!r}")
    if receipt.get('dirtyBefore') is not False or receipt.get('dirtyAfter') is not False:
        problems.append('project tab was dirty')
    before, after = receipt.get('stateChangeCountBefore'), receipt.get('stateChangeCountAfter')
    if before is None or before != after:
        problems.append(f'project state change count {before!r} -> {after!r}')
    if not receipt.get('exporterVersion'):
        problems.append('missing exporterVersion')
    if problems:
        raise RuntimeError('Saved-only receipt rejected: ' + '; '.join(problems))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mailbox', type=Path, default=DEFAULT_MAILBOX)
    parser.add_argument('--timeout', type=float, default=30)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('ping', 'projects', 'stop'):
        commands.add_parser(name)
    export = commands.add_parser('export-clicks', help='Native measure beat-grid JSON, one file per region')
    export.add_argument('--project', type=Path, help='Exact saved path of an open project; defaults to current live project')
    export.add_argument('--open-project', action='store_true', help='Open a saved RPP in an own temporary tab if needed')
    export.add_argument('--region', help='Exact region name; omit to export all regions')
    export.add_argument('--output', type=Path, required=True, help='Parent output directory; each request gets a unique subfolder')
    export.add_argument('--saved-only', action='store_true',
                        help='Require --project to be an exact, clean (saved) tab that stays unchanged during export')
    export.add_argument('--grid-only', action='store_true', help='Explicitly ignore custom metronome patterns; never infer authored exceptions')
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error('--timeout must be between 1 and 300 seconds')
    fields = {}
    if args.command == 'export-clicks':
        if args.open_project and not args.project:
            parser.error('--open-project requires --project')
        if args.saved_only and not args.project:
            parser.error('--saved-only requires --project')
        output = args.output.expanduser().resolve()
        output.mkdir(parents=True, exist_ok=True)
        fields = dict(output=str(output), open_project=int(args.open_project), grid_only=int(args.grid_only))
        if args.project:
            fields['project'] = str(args.project.expanduser().resolve())
        if args.region:
            fields['region'] = args.region
        if args.saved_only:
            # Sent only when requested so callers without the flag keep working with older loaded bridges.
            fields['saved_only'] = 1
    try:
        result = request(args.mailbox, args.command, fields, args.timeout)
        if args.command == 'export-clicks' and args.saved_only and result.get('ok'):
            verify_saved_only(result, fields['project'])
        print(json.dumps(result, indent=2))
        return 0 if result['ok'] else 1
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        print(json.dumps(dict(ok=False, error=str(error))), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
