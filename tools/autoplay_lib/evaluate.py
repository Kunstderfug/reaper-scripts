"""Native evaluation and exact discrepancy approval for click delivery."""
import json
import math
import re
import shlex
from pathlib import Path

from .opus import decode_clicks, DETECTOR_VERSION
from .rpp import children
from .support import (check_fingerprints, file_digest, identity,
                      tool_fingerprints, write_json)


def audit_rpp_integrity(project, plan):
    """Text-level writer-regression and integrity guard before native export.

    evaluate() already verifies the saved RPP's SHA-256 against its build
    receipt, so this checks invariants that beat-grid exports cannot observe
    (without reading back REAPER's decoded audio PCM): project TIMELOCKMODE 1,
    track/item BEAT timebases, MP3 gapless flag ('FILE "<path>" 1'), strict
    PLAYRATE 1 and SOFFS 0, orchestra LENGTH and POSITION parity, OPUS item
    presence and POSITION parity, and resolved media file paths on disk.
    """
    project = Path(project).resolve()
    lines = project.read_text(encoding='utf-8-sig').splitlines()
    planned_by_name = {s['region_name']: s for s in plan['sections']}
    timelock = None
    orch_items = {}
    opus_items = {}
    for chunk in children(lines):
        head = chunk[0].strip()
        if head.startswith('TIMELOCKMODE '):
            timelock = head.split()[1]
            continue
        if not head.startswith('<TRACK '):
            continue
        parts = list(children(chunk))
        track_beat = None
        track_items = []
        for part in parts:
            phead = part[0].strip()
            if phead.startswith('BEAT '):
                track_beat = phead.split()[1]
            elif phead == '<ITEM':
                track_items.append(part)
        if not track_items:
            continue
        # Only audit pipeline-managed tracks (containing planned items or a CLICK source)
        # so unrelated template routing tracks passed through unchanged do not abort.
        parsed_items = []
        track_has_click = False
        track_has_managed_media = False
        for item_lines in track_items:
            item_parts = list(children(item_lines))
            fields = {}
            src_chunk = None
            for part in item_parts:
                phead = part[0].strip()
                if phead.startswith('<SOURCE '):
                    src_chunk = part
                else:
                    tokens = phead.split(None, 1)
                    if len(tokens) == 2:
                        fields[tokens[0]] = tokens[1]
            if src_chunk is None or 'NAME' not in fields or 'POSITION' not in fields or 'PLAYRATE' not in fields:
                continue
            src_type = src_chunk[0].strip().split()[1]
            name = shlex.split(fields['NAME'])[0]
            if src_type == 'CLICK':
                track_has_click = True
            if name in planned_by_name and src_type != 'CLICK':
                track_has_managed_media = True
            parsed_items.append((name, fields, src_type, src_chunk))
        if not (track_has_click or track_has_managed_media):
            continue
        if track_has_click and track_beat != '-1':
            raise ValueError(f'Click track in {project.name} must inherit Beats (BEAT -1), got {track_beat}')
        if track_has_managed_media and track_beat != '0':
            raise ValueError(f'Media track in {project.name} must be Time-locked (BEAT 0), got {track_beat}')
        for name, fields, src_type, src_chunk in parsed_items:
            if src_type == 'CLICK':
                continue
            pos = float(fields['POSITION'])
            length = float(fields.get('LENGTH', 'nan'))
            rate = float(fields['PLAYRATE'].split()[0])
            soffs = float(fields.get('SOFFS', '0'))
            item_beat = fields.get('BEAT')
            if abs(rate - 1.0) > 1e-9:
                raise ValueError(f'Stretched media item in {project.name}: {name} ({src_type}) has PLAYRATE {rate}')
            if abs(soffs) > 1e-9:
                raise ValueError(f'Non-zero SOFFS in {project.name}: {name} ({src_type}) has SOFFS {soffs}')
            if item_beat != '0':
                raise ValueError(f'Media item {name} ({src_type}) must be Time-locked (BEAT 0), got {item_beat}')
            file_line = next((l.strip() for l in src_chunk[1:-1] if l.strip().startswith('FILE ')), None)
            if not file_line:
                raise ValueError(f'Missing FILE entry in {project.name}: {name} ({src_type})')
            file_tokens = shlex.split(file_line[5:])
            media_path = Path(file_tokens[0])
            if not media_path.is_absolute():
                media_path = (project.parent / media_path).resolve()
            if not media_path.is_file():
                raise ValueError(f'Unresolved media path in {project.name}: {file_tokens[0]}')
            if src_type == 'MP3':
                if len(file_tokens) < 2 or file_tokens[1] != '1':
                    raise ValueError(
                        f'MP3 item {name} lacks trailing gapless flag "1" (REAPER defaults to legacy padding mode 0)'
                    )
            if src_type == 'OPUS':
                opus_items[name] = (pos, length)
            else:
                orch_items[name] = (pos, length)
    if timelock != '1':
        raise ValueError(f'Project {project.name} must use Beats timebase (TIMELOCKMODE 1), got {timelock}')
    for region_name, section in planned_by_name.items():
        expected_pos = section['start_seconds']
        expected_len = section['audio_duration_seconds']
        if region_name not in orch_items:
            raise ValueError(f'Missing orchestra item for section {region_name}')
        orch_pos, orch_len = orch_items[region_name]
        if abs(orch_pos - expected_pos) > 1e-6:
            raise ValueError(
                f'Orchestra item position drift for {region_name}: {orch_pos} vs {expected_pos}'
            )
        if abs(orch_len - expected_len) > 1e-6:
            raise ValueError(
                f'Orchestra item length mismatch for {region_name}: {orch_len} vs {expected_len}'
            )
        if section.get('opus_path'):
            if region_name not in opus_items:
                raise ValueError(f'Missing OPUS reference item for section {region_name}')
            opus_pos, _ = opus_items[region_name]
            if abs(opus_pos - expected_pos) > 1e-6:
                raise ValueError(
                    f'OPUS item position drift for {region_name}: {opus_pos} vs {expected_pos}'
                )


def validate_clicks(clicks, duration_ms):
    if not isinstance(clicks, list) or not clicks:
        raise ValueError('Expected nonempty click events')
    previous = -1
    for click in clicks:
        if (set(click) != {'time', 'beat'} or type(click['time']) is not int or
                type(click['beat']) is not int or not previous < click['time'] < duration_ms or
                click['beat'] < 1):
            raise ValueError('Invalid, colliding or out-of-region click')
        previous = click['time']


def compare_events(expected, actual, tolerance_ms=1):
    differences = []
    if len(expected) != len(actual):
        differences.append({'kind': 'count', 'expected': len(expected), 'actual': len(actual)})
    for i, (left, right) in enumerate(zip(expected, actual)):
        if abs(left['time'] - right['time']) > tolerance_ms or left['beat'] != right['beat']:
            differences.append({'kind': 'event', 'index': i, 'expected': left, 'actual': right})
    return differences


def compare_reference(generated, reference, comparison=None):
    """No automatic fitting: the user-reviewed mapping precedes comparison."""
    comparison = comparison or {}
    if 'start_ms' in comparison or 'end_ms' in comparison:
        raise ValueError('Comparison windows are unsupported; review the full OPUS discrepancy')
    scale = comparison.get('time_scale', 1.0)
    offset = comparison.get('offset_ms', 0.0)
    tolerance = comparison.get('tolerance_ms', 3)
    if (any(type(v) not in (int, float) or not math.isfinite(v)
            for v in (scale, offset, tolerance)) or
            not (0 < scale < 100) or not (0 <= tolerance <= 20)):
        raise ValueError('Invalid OPUS comparison scale or tolerance')
    scale, offset, tolerance = map(float, (scale, offset, tolerance))
    transformed = [{'time': int(c['time'] * scale + offset + .5), 'beat': c['beat']} for c in reference]
    left, right = generated, transformed
    if not left or not right:
        raise ValueError('OPUS comparison interval contains no clicks')
    differences = compare_events(left, right, tolerance)
    mapping = {'time_scale': scale, 'offset_ms': offset, 'tolerance_ms': tolerance}
    if scale != 1 or offset != 0 or tolerance > 3:
        differences.append({'kind': 'comparison_mapping', **mapping})
    fingerprint = identity({'mapping': mapping, 'differences': differences})
    approved = not differences or (
        comparison.get('approved_discrepancy_sha256') == fingerprint and
        bool(comparison.get('approval_note')))
    return {'detector': DETECTOR_VERSION, 'generated_count': len(left), 'reference_count': len(right),
            'differences': differences, 'discrepancy_sha256': fingerprint,
            'approved': bool(approved)}


def native_export(project, output, bridge_request=None, mailbox=None):
    from reaper_bridge import verify_saved_only
    if bridge_request is None:
        from reaper_bridge import request, DEFAULT_MAILBOX
        bridge_request, mailbox = request, mailbox or DEFAULT_MAILBOX
    fields = {'project': str(project), 'output': str(output), 'open_project': '1',
              'saved_only': '1', 'grid_only': '0'}
    response = bridge_request(mailbox, 'export-clicks', fields, 120)
    if not response.get('ok'):
        raise ValueError(response.get('error', 'Native export failed'))
    verify_saved_only(response, str(project))
    result = response['result']
    if result.get('openedOwnTab') is not True:
        raise ValueError('AUTOPLAY.RPP is already open in REAPER (possibly an earlier build); close that tab and re-run')
    if (result.get('project') != str(project) or result.get('savedOnly') is not True or
            result.get('dirtyBefore') or result.get('dirtyAfter') or
            result.get('stateChangeCountBefore') != result.get('stateChangeCountAfter')):
        raise ValueError('Native export is not bound to an unchanged clean saved project')
    return result


def evaluate(manifest_path, manifest, plan, project, output, fingerprints,
             bridge_request=None, mailbox=None, decoder=decode_clicks):
    """Create JSON only from native readback; offline predictions are checks."""
    project, output = Path(project).resolve(), Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    build_receipt = project.with_suffix(project.suffix + '.receipt.json')
    if not build_receipt.is_file() or json.loads(build_receipt.read_text()).get('sha256') != file_digest(project):
        raise ValueError('Saved project differs from its generated build receipt')
    before = dict(fingerprints)
    before[str(Path(manifest_path).resolve())] = file_digest(manifest_path)
    before[str(project)] = file_digest(project)
    before[str(build_receipt)] = file_digest(build_receipt)
    before.update(tool_fingerprints())
    check_fingerprints(before)
    audit_rpp_integrity(project, plan)
    native = native_export(project, output / 'native', bridge_request, mailbox)
    check_fingerprints(before)
    files = native.get('files', [])
    native_by_name = {}
    for file in files:
        name = file['region']['name']
        if name in native_by_name:
            raise ValueError('Duplicate region in native export')
        native_by_name[name] = file
    expected_names = {s['region_name'] for s in plan['sections']}
    if set(native_by_name) != expected_names:
        raise ValueError('Native export region set differs from compiled plan')
    sections, issues = [], []
    source_sections = {s['key']: s for s in manifest['sections']}
    for section in plan['sections']:
        key = section['key']
        record = source_sections[key]
        file = native_by_name[section['region_name']]
        region = file['region']
        for native_field, plan_field in [('start', 'start_seconds'), ('finish', 'end_seconds')]:
            if abs(region[native_field] - section[plan_field]) > .000001:
                raise ValueError('Native region bounds changed: ' + section['name'])
        clicks = json.loads(Path(file['path']).read_text())
        duration_ms = (section['end_seconds'] - section['start_seconds']) * 1000
        validate_clicks(clicks, duration_ms)
        differences = compare_events(section['expected_clicks'], clicks)
        if differences:
            issues.append({'section': key, 'kind': 'native_grid', 'differences': differences})
        # Custom audible pulse insertions require a qualified rendered-click
        # implementation. Never label grid-only evidence as audible proof.
        if record.get('click_exceptions'):
            issues.append({'section': key, 'kind': 'rendered_click_exception_verification_required'})
        opus = Path(manifest['project_root']) / record['opus_path']
        comparison = compare_reference(clicks, decoder(opus), record.get('comparison'))
        if not comparison['approved']:
            issues.append({'section': key, 'kind': 'opus_discrepancy',
                           'discrepancy_sha256': comparison['discrepancy_sha256']})
        destination = record.get('storage_path')
        local_path = output / 'CLICKDATA' / (section['region_name'] + '.json')
        write_json(local_path, clicks)
        handoff = section.get('handoff_seconds')
        metadata = {'defaultSectionLength': duration_ms / 1000,
                    'autoContinue': handoff is not None}
        if handoff is not None:
            metadata['autoContinueMarker'] = handoff - section['start_seconds']
        sections.append({'key': key, 'name': section['name'], 'region_name': section['region_name'],
                         'storage_path': destination, 'path': str(local_path),
                         'sha256': file_digest(local_path), 'comparison': comparison,
                         'click_count': len(clicks), 'duration_seconds': duration_ms / 1000,
                         'handoff_seconds': handoff, 'metadata': metadata})
    check_fingerprints(before)
    receipt = {'schema': 1, 'status': 'evaluated' if not issues else 'blocked',
               'manifest_path': str(Path(manifest_path).resolve()), 'project': str(project),
               'fingerprints': before, 'sanity': manifest.get('sanity'),
               'sections': sections, 'issues': issues, 'native': native,
               'proof': 'Native beat grid and offline timing; no audible playback claim'}
    receipt['evaluation_id'] = identity(receipt)
    write_json(output / 'evaluation.json', receipt)
    return receipt


def validate_receipt(receipt):
    if receipt.get('schema') != 1 or receipt.get('status') != 'evaluated' or receipt.get('issues'):
        raise ValueError('Delivery requires an evaluated receipt without unresolved discrepancies')
    content = {k: v for k, v in receipt.items() if k != 'evaluation_id'}
    if receipt.get('evaluation_id') != identity(content):
        raise ValueError('Evaluation receipt changed')
    check_fingerprints(receipt['fingerprints'])
    paths = {}
    for section in receipt['sections']:
        path = section['storage_path']
        if not path or path in paths:
            raise ValueError('Missing or duplicate click delivery destination')
        paths[path] = section['sha256']
        if file_digest(section['path']) != section['sha256']:
            raise ValueError('Evaluated click JSON changed: ' + section['name'])
        validate_clicks(json.loads(Path(section['path']).read_text()), section['duration_seconds'] * 1000)
    return receipt
