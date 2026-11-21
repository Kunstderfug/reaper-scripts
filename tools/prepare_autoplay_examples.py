#!/usr/bin/env python3
"""Collect actual example movements without changing their original projects."""
import argparse
import json
from pathlib import Path

from autoplay_lib import prepare_manifest, questions
from autoplay_lib.support import write_json


def prepare_examples(project_root, template, output, catalog=None):
    catalog = catalog or Path(__file__).resolve().parents[1] / 'examples/autoplay/catalog.json'
    rows = []
    for work in json.loads(catalog.read_text())['works']:
        snapshot_path = catalog.parent / work['snapshot']
        score = json.loads(snapshot_path.read_text())
        for item in work['movements']:
            folder = output / (score['pathName'] + '_' + str(item['index']))
            manifest_path = folder / 'movement.json'
            if manifest_path.exists():
                rows.append({'work': work['name'], 'movement': item['index'], 'status': 'preserved',
                             'manifest': str(manifest_path)})
                continue
            try:
                movement = next(m for m in score['movements'] if m['index'] == item['index'])
                manifest = prepare_manifest(item['source'], str(template), str(snapshot_path),
                                            movement['_key'], project_root,
                                            media_directory=str(Path(item['source']).parent))
                manifest['example_kind'] = work['kind']
                manifest['delivery'] = {'storage_url': 'https://gprktgiajxiwjzjsqdly.supabase.co',
                                        'bucket': score['slug']['current'], 'changes': []}
                manifest['sanity'].update(project_id='b8uar5wl', dataset='production', api_version='v2025-11-10')
                write_json(manifest_path, manifest)
                missing = questions(manifest)
                write_json(folder / 'questions.json', missing)
                rows.append({'work': work['name'], 'movement': item['index'], 'status': 'prepared',
                             'sections': len(manifest['sections']), 'questions': len(missing),
                             'manifest': str(manifest_path)})
            except (OSError, ValueError, KeyError, StopIteration) as error:
                rows.append({'work': work['name'], 'movement': item['index'], 'status': 'blocked',
                             'source': item['source'], 'error': str(error)})
    write_json(output / 'inventory.json', rows)
    return rows


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-root', type=Path, required=True)
    parser.add_argument('--template', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare_examples(args.project_root.resolve(), args.template.resolve(), args.output.resolve()), indent=2))
