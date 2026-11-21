#!/usr/bin/env python3
"""Qualify a synthetic rebuild in the already-running REAPER; never publish."""
import argparse
from array import array
import json
import math
from pathlib import Path
import subprocess
import wave

from autoplay import build
from autoplay_lib import prepare_manifest, compile_manifest, input_fingerprints
from autoplay_lib.evaluate import audit_rpp_integrity, compare_reference, evaluate
from autoplay_lib.opus import decode_clicks
from autoplay_lib.manifest import timing_review_sha256
from autoplay_lib.support import write_json


def wave_file(path, samples, rate=48000):
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), 'wb') as stream:
        stream.setparams((1, 2, rate, 0, 'NONE', ''))
        data = array('h', (round(max(-1, min(1, s)) * 32767) for s in samples))
        import sys
        if sys.byteorder != 'little':
            data.byteswap()
        stream.writeframes(data.tobytes())


def fixture(root):
    """Known, invented 2/4 music: silence after .5 s; a last-beat hold at .6."""
    source = root / 'source.RPP'
    source.write_text('<REAPER_PROJECT 0.1 7.86 1\n  TEMPO 100 2 4\n'
                      '  MARKER 1 0 A 1\n  MARKER 1 2.4 "" 1\n'
                      '  MARKER 2 12 B 1\n  MARKER 2 14.4 "" 1\n>\n')
    template = root / 'template.RPP'
    template.write_text('<REAPER_PROJECT 0.1 7.86 1\n' + ''.join(
        f'  <TRACK {{00000000-0000-0000-0000-00000000000{index}}}\n    NAME "{name}"\n    MAINSEND 1 0\n  >\n'
        for index, name in enumerate(('', '', 'CLICKS'), 1)) + '>\n')
    score = {'_id': 'synthetic-only', '_rev': 'fixture-1', 'pathName': 'DEMO',
             'slug': {'current': 'never-upload'}, 'movements': [{'_key': 'm', 'index': 1,
             'sections': [{'_key': 'a', 'name': 'A', 'defaultTempo': 100,
                           'defaultSectionLength': 3, 'autoContinue': True,
                           'autoContinueMarker': 2.4},
                          {'_key': 'b', 'name': 'B', 'defaultTempo': 100,
                           'defaultSectionLength': 3}]}]}
    write_json(root / 'snapshot.json', score)
    samples = [0.] * 144000
    for beat in range(5):
        start = round(beat * .6 * 48000)
        amplitude = .85 if beat % 2 == 0 else .22
        for i in range(960):
            samples[start + i] = amplitude * math.exp(-i / 300) * math.sin(i * 2 * math.pi * 1200 / 48000)
    reference = root / 'reference.wav'
    wave_file(reference, samples)
    for name in ('A', 'B'):
        wave_file(root / f'AUDIO/{name}/DEMO_1_{name}_100.wav', [0.] * 24000)
        opus = root / f'CLICKDATA/DEMO_1_{name}_100.opus'
        opus.parent.mkdir(exist_ok=True)
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', str(reference),
                        '-c:a', 'libopus', str(opus)], check=True)
    manifest = prepare_manifest(source, template, root / 'snapshot.json', 'm', root)
    for section in manifest['sections']:
        section['decision'] = {'approved': True, 'reviewer': 'synthetic-fixture-author',
            'evidence': 'source.RPP', 'source_to_render_scale': 1,
            'audio_sha256': manifest['fingerprints'][section['audio_path']],
            'handoff_basis': 'source'}
    manifest['sections'][1]['overlap_owner'] = 'b'
    manifest['sections'][0]['fermatas'] = [{
        'source_seconds': .6, 'source_end_seconds': 1.2, 'duration_beats': 2,
        'window': 'verified_solo', 'approved': True,
        'reviewer': 'synthetic-fixture-author', 'evidence': 'source.RPP'}]
    return manifest


def qualify(output):
    if output.exists():
        raise ValueError('Choose a new output directory; qualification preserves prior evidence')
    output.mkdir(parents=True)
    manifest = fixture(output)
    results = []
    for beats, expected_start in ((2, 3.0), (3, 3.6)):
        manifest['sections'][0]['fermatas'][0]['duration_beats'] = beats
        plan = compile_manifest(manifest)
        if plan['issues']:
            raise ValueError(str(plan['issues']))
        if abs(plan['sections'][1]['start_seconds'] - expected_start) > 1e-8:
            raise ValueError('Single-value fermata edit failed to move the next section')
        # Only this invented fixture approves its known hold-versus-reference
        # discrepancy. Production preparation never grants such approval.
        for record, section in zip(manifest['sections'], plan['sections']):
            comparison = compare_reference(section['expected_clicks'],
                decode_clicks(output / record['opus_path']), record['comparison'])
            record['comparison'].update(
                approved_discrepancy_sha256=comparison['discrepancy_sha256'],
                approval_note='Synthetic known hold and overlap; not a production approval')
        path = output / f'hold-{beats}.json'
        write_json(path, manifest)
        destination = output / f'hold-{beats}'
        report, plan = build(path, manifest, destination)
        if report['status'] != 'built':
            raise ValueError(str(report))
        receipt = evaluate(path, manifest, plan, destination / 'AUTOPLAY.RPP',
                           destination, input_fingerprints(manifest))
        if receipt['status'] != 'evaluated':
            raise ValueError(str(receipt['issues']))
        results.append({'hold_beats': beats, 'incoming_start_seconds': expected_start,
                        'status': receipt['status'], 'project': report['output_path'],
                        'receipt': str(destination / 'evaluation.json')})
    results.append(qualify_partial_reset(output / 'partial-reset'))
    results.append(qualify_mp3_gapless(output / 'mp3-gapless'))
    write_json(output / 'qualification.json', results)
    return results


def qualify_mp3_gapless(root):
    """Text-level guard for LAME MP3 gapless flag ('1'), rate-1, and rejection of '0'.

    Note: verifies RPP writer/auditor integrity and native beat-grid export
    with real LAME MP3 media; does not read back REAPER's decoded MP3 PCM.
    """
    root.mkdir()
    fixture(root)
    # Replace silent WAVs with a real LAME-encoded transient MP3 carrying Xing/LAME delay headers.
    mp3_ref = root / 'reference.wav'
    for name in ('A', 'B'):
        wav_path = root / f'AUDIO/{name}/DEMO_1_{name}_100.wav'
        wav_path.unlink()
        mp3_path = root / f'AUDIO/{name}/DEMO_1_{name}_100.mp3'
        subprocess.run(
            ['ffmpeg', '-nostdin', '-v', 'error', '-i', str(mp3_ref),
             '-c:a', 'libmp3lame', '-q:a', '4', str(mp3_path)],
            check=True,
        )
    manifest = prepare_manifest(root / 'source.RPP', root / 'template.RPP',
                                root / 'snapshot.json', 'm', root)
    for section in manifest['sections']:
        section['decision'] = {
            'approved': True, 'reviewer': 'synthetic-fixture-author',
            'evidence': 'source.RPP', 'source_to_render_scale': 1,
            'audio_sha256': manifest['fingerprints'][section['audio_path']],
            'handoff_basis': 'source',
        }
    manifest['sections'][1]['overlap_owner'] = 'b'
    plan = compile_manifest(manifest)
    if plan['issues']:
        raise ValueError(str(plan['issues']))
    path = root / 'movement.json'
    write_json(path, manifest)
    report, plan = build(path, manifest, root / 'BUILD')
    if report['status'] != 'built':
        raise ValueError(str(report))
    rpp = root / 'BUILD/AUTOPLAY.RPP'
    audit_rpp_integrity(rpp, plan)
    # Prove legacy MP3 flag '0' is rejected by audit_rpp_integrity before native export.
    bad_rpp = root / 'BUILD/BAD_LEGACY_MP3.RPP'
    bad_rpp.write_text(rpp.read_text().replace('.mp3" 1', '.mp3" 0', 1))
    try:
        audit_rpp_integrity(bad_rpp, plan)
    except ValueError as err:
        if 'gapless flag' not in str(err):
            raise
    else:
        raise ValueError('audit_rpp_integrity failed to reject legacy MP3 flag 0')
    bad_rpp.unlink()
    receipt = evaluate(path, manifest, plan, rpp, root / 'BUILD',
                       input_fingerprints(manifest))
    if receipt['status'] != 'evaluated':
        raise ValueError(str(receipt['issues']))
    return {'case': 'mp3-gapless-integrity', 'status': receipt['status'],
            'proof': 'Text-level MP3 gapless flag guard and native beat-grid export; no decoded-PCM audio readback',
            'project': report['output_path'], 'receipt': str(root / 'BUILD/evaluation.json')}


def qualify_partial_reset(root):
    """Reviewed data can recover a bad legacy pattern and reset between beats."""
    root.mkdir()
    fixture(root)
    source = root / 'source.RPP'
    source.write_text('<REAPER_PROJECT 0.1 7.86 1\n  TEMPO 120 4 4\n'
                      '  MARKER 1 0 A 1\n  MARKER 1 2 "" 1\n'
                      '  <TEMPOENVEX\n'
                      '    PT 0 120 1 262148 1 1 0 "" 0 0 0 ....\n  >\n>\n')
    snapshot = root / 'snapshot.json'
    score = json.loads(snapshot.read_text())
    score['movements'][0]['sections'] = [
        {'_key': 'a', 'name': 'A', 'defaultTempo': 100, 'defaultSectionLength': 3}]
    write_json(snapshot, score)
    manifest = prepare_manifest(source, root / 'template.RPP', snapshot, 'm', root)
    record = manifest['sections'][0]
    record['decision'] = {'approved': True, 'reviewer': 'synthetic-fixture-author',
        'evidence': 'source.RPP', 'source_to_render_scale': 1,
        'audio_sha256': manifest['fingerprints'][record['audio_path']]}
    manifest['source_timing_override'] = {
        'points': [{'time': 0, 'bpm': 120, 'shape': 1},
                   {'time': .75, 'bpm': 120, 'shape': 1}],
        'meter_anchors': [{'time': 0, 'numerator': 4, 'denominator': 4},
                          {'time': .75, 'numerator': 4, 'denominator': 4, 'reset': True}],
        'approved': True, 'reviewer': 'synthetic-fixture-author', 'evidence': 'source.RPP'}
    manifest['partial_measure_decision'] = {'policy': 'reset', 'approved': True,
        'reviewer': 'synthetic-fixture-author', 'evidence': 'source.RPP'}
    manifest['source_timing_override']['approved_sha256'] = timing_review_sha256(manifest)
    plan = compile_manifest(manifest)
    expected = [{'time': t, 'beat': b} for t, b in
                ((0, 1), (500, 2), (750, 1), (1250, 2), (1750, 3), (2250, 4), (2750, 1))]
    if plan['issues'] or plan['sections'][0]['expected_clicks'] != expected:
        raise ValueError('Partial reset failed independent fixture expectation')
    comparison = compare_reference(expected, decode_clicks(root / record['opus_path']))
    record['comparison'].update(approved_discrepancy_sha256=comparison['discrepancy_sha256'],
                               approval_note='Synthetic reset differs intentionally from old 2/4 reference')
    path = root / 'movement.json'
    write_json(path, manifest)
    report, plan = build(path, manifest, root / 'BUILD')
    receipt = evaluate(path, manifest, plan, root / 'BUILD/AUTOPLAY.RPP', root / 'BUILD',
                       input_fingerprints(manifest))
    if receipt['status'] != 'evaluated':
        raise ValueError(str(receipt['issues']))
    return {'case': 'reviewed-partial-reset', 'status': receipt['status'],
            'project': report['output_path'], 'receipt': str(root / 'BUILD/evaluation.json')}


if __name__ == '__main__':
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--output', type=Path, required=True)
    print(json.dumps(qualify(cli.parse_args().output.resolve()), indent=2))
