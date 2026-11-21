#!/usr/bin/env python3
"""Prepare, rebuild, check and deliver data-driven GPhil AUTOPLAY projects."""
import argparse
import csv
import json
from pathlib import Path
import sys

from autoplay_lib import (prepare_manifest, load_manifest, compile_manifest,
                          write_project, questions, input_fingerprints)
from autoplay_lib.delivery import deliver
from autoplay_lib.evaluate import evaluate
from autoplay_lib.remote import credentials, Sanity
from autoplay_lib.support import file_digest, write_json


def build(manifest_path, manifest, output):
    plan = compile_manifest(manifest)
    write_json(output / 'build-plan.json', plan)
    if plan['issues']:
        return {'status': 'blocked', 'issues': plan['issues'], 'plan': str(output / 'build-plan.json')}, plan
    report = write_project(manifest, plan, output / 'AUTOPLAY.RPP')
    with (output / 'regions.csv').open('w', newline='') as stream:
        writer = csv.writer(stream)
        writer.writerow(['#', 'Name', 'Start', 'End', 'Length'])
        for index, section in enumerate(plan['sections'], 1):
            start, end = section['start_seconds'], section['end_seconds']
            writer.writerow([f'R{index}', section['region_name'], f'{start:.3f}', f'{end:.3f}', f'{end-start:.3f}'])
    report.update(status='built', manifest_sha256=file_digest(manifest_path),
                  regions=len(plan['sections']), regions_csv=str(output / 'regions.csv'))
    write_json(output / 'build.json', report)
    return report, plan


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--env-file', type=Path, help='Read credentials as data; process environment takes precedence')
    cli.add_argument('--secrets-plist', type=Path, help='Existing local ignored Scoremaker Secrets.plist')
    sub = cli.add_subparsers(dest='command', required=True)
    fetch = sub.add_parser('fetch', help='Read canonical Sanity score; refuse unpublished drafts')
    fetch.add_argument('--score-id', required=True)
    fetch.add_argument('--project-id', required=True)
    fetch.add_argument('--dataset', default='production')
    fetch.add_argument('--api-version', default='v2025-11-10')
    fetch.add_argument('--output', type=Path, required=True)
    prepare = sub.add_parser('prepare', help='Collect evidence and open musical decisions; never auto-approve')
    for name in ('source', 'template', 'sanity-snapshot', 'project-root'):
        prepare.add_argument('--' + name, type=Path, required=True)
    prepare.add_argument('--movement-key', required=True)
    prepare.add_argument('--media-directory', type=Path)
    prepare.add_argument('--output', type=Path, required=True)
    for command in ('questions', 'plan', 'build', 'evaluate', 'deliver', 'run'):
        item = sub.add_parser(command)
        item.add_argument('manifest', type=Path)
        item.add_argument('--project-root', type=Path)
        if command != 'questions':
            item.add_argument('--output', type=Path, required=True, help='Build/evaluation directory')
        if command in ('deliver', 'run'):
            item.add_argument('--publish', action='store_true', help='Upload verified clicks and publish guarded refresh metadata')
    return cli


def execute(args):
    values = credentials(args.env_file, args.secrets_plist)
    if args.command == 'fetch':
        if args.output.exists():
            raise ValueError('Snapshot output already exists; choose a new evidence path')
        config = {'project_id': args.project_id, 'dataset': args.dataset, 'api_version': args.api_version}
        score = Sanity(config, values).read(args.score_id)
        write_json(args.output, score)
        return {'status': 'fetched', 'score_id': score['_id'], 'revision': score['_rev'], 'path': str(args.output)}
    if args.command == 'prepare':
        if args.output.exists():
            raise ValueError('Manifest already exists; preserve its reviewed decisions')
        manifest = prepare_manifest(args.source, args.template, args.sanity_snapshot,
                                    args.movement_key, args.project_root,
                                    media_directory=args.media_directory or args.source.parent)
        write_json(args.output, manifest)
        return {'status': 'prepared', 'path': str(args.output), 'questions': questions(manifest)}
    manifest = load_manifest(args.manifest, project_root=args.project_root)
    if args.command == 'questions':
        return {'status': 'needs_review' if questions(manifest) else 'ready', 'questions': questions(manifest)}
    output = args.output.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.command == 'plan':
        plan = compile_manifest(manifest)
        write_json(output / 'build-plan.json', plan)
        return {'status': 'blocked' if plan['issues'] else 'planned', 'issues': plan['issues'],
                'sections': len(plan['sections']), 'path': str(output / 'build-plan.json')}
    if args.command == 'deliver':
        receipt = json.loads((output / 'evaluation.json').read_text())
        return deliver(manifest, receipt, output / ('delivery-' + receipt['evaluation_id'][:12] + '.json'),
                       values=values, apply=args.publish)
    report, plan = build(args.manifest, manifest, output)
    if report['status'] == 'blocked' or args.command == 'build':
        return report
    receipt = evaluate(args.manifest, manifest, plan, output / 'AUTOPLAY.RPP', output,
                       input_fingerprints(manifest))
    if args.command == 'evaluate' or receipt['status'] == 'blocked':
        return {'status': receipt['status'], 'issues': receipt['issues'],
                'path': str(output / 'evaluation.json')}
    return deliver(manifest, receipt, output / ('delivery-' + receipt['evaluation_id'][:12] + '.json'),
                   values=values, apply=args.publish)


def main():
    args = parser().parse_args()
    try:
        result = execute(args)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 2 if result.get('status') in ('blocked', 'needs_review') else 0
    except (ValueError, OSError, RuntimeError, KeyError) as error:
        print(json.dumps({'status': 'failed', 'error': str(error)}), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
