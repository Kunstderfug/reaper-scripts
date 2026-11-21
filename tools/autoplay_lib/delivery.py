"""Preview, verify and journal click-only delivery; publish metadata last."""
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import uuid

from .evaluate import validate_receipt
from .remote import Sanity, Storage, storage_path
from .support import digest_bytes, identity, json_bytes, write_json


def keyed(items, key, description):
    matches = [item for item in items if item.get('_key') == key]
    if len(matches) != 1:
        raise ValueError('Expected one ' + description + ': ' + key)
    return matches[0]


def check_score(score, target):
    if score['_id'] != target['score_id'] or score['_rev'] != target['revision']:
        raise ValueError('Sanity revision changed; fetch and reconcile before delivery')
    return keyed(score['movements'], target['movement_key'], 'movement')


def publication_values(score, target, sections):
    movement = check_score(score, target)
    values = {}
    for section in sections:
        keyed(movement['sections'], section['key'], 'section')
        prefix = ('movements[_key==' + json.dumps(target['movement_key']) +
                  '].sections[_key==' + json.dumps(section['key']) + ']')
        allowed = {'defaultSectionLength', 'autoContinue', 'autoContinueMarker',
                   'beatsPerBar', 'beatLength'}
        metadata = section.get('metadata', {})
        if set(metadata) - allowed:
            raise ValueError('Unsupported click publication metadata')
        for name, value in dict(metadata, updateRequired=True).items():
            values[prefix + '.' + name] = value
    return values


def delivery_plan(manifest, receipt, storage, sanity):
    validate_receipt(receipt)
    target = manifest['sanity']
    if receipt.get('sanity') != target:
        raise ValueError('Evaluation target differs from delivery target')
    score = sanity.read(target['score_id'])
    check_score(score, target)
    config = manifest['delivery']
    slug = score.get('slug', {})
    slug = slug.get('current') if isinstance(slug, dict) else slug
    if config['bucket'] != slug:
        raise ValueError('Delivery bucket does not match the current Sanity score slug')
    objects = []
    for section in receipt['sections']:
        path = section['storage_path']
        storage_path(path)
        if not path.startswith(str(target['movement_index']) + '/CLICKDATA/') or not path.endswith('.json'):
            raise ValueError('Click destination is outside this movement CLICKDATA')
        before = storage.read(path)
        before_hash = digest_bytes(before) if before is not None else None
        objects.append(dict(section=section['key'], path=path, local_path=section['path'],
                            before_sha256=before_hash, after_sha256=section['sha256'],
                            changed=before_hash != section['sha256']))
    return {'schema': 1, 'evaluation_id': receipt['evaluation_id'], 'target': target,
            'bucket': config['bucket'], 'objects': objects, 'score_revision': score['_rev']}


def expected_score(score, target, sections, entry):
    expected = deepcopy(score)
    movement = keyed(expected['movements'], target['movement_key'], 'movement')
    for section in sections:
        row = keyed(movement['sections'], section['key'], 'section')
        row.update(section.get('metadata', {}))
        row['updateRequired'] = True
    expected.setdefault('changelog', []).append(entry)
    return expected


def strip_system(score):
    return {k: v for k, v in score.items() if k not in ('_rev', '_updatedAt')}


def deliver(manifest, receipt, journal_path, values=None, apply=False,
            storage=None, sanity=None):
    """Local preview is read-only remotely. Apply requires all evaluation gates.

    The create-only Storage lock serializes cooperating pipeline publishers.
    Other upload tools must not write the same objects during delivery. There
    is no cross-service transaction or claim of universal Storage CAS.
    """
    validate_receipt(receipt)
    values = values or {}
    storage = storage or Storage(manifest['delivery'], values)
    sanity = sanity or Sanity(manifest['sanity'], values)
    journal_path = Path(journal_path)
    previous = json.loads(journal_path.read_text()) if journal_path.exists() else None
    if previous and previous['evaluation_id'] != receipt['evaluation_id']:
        raise ValueError('Delivery journal belongs to another evaluation; choose a new output directory')
    if previous and previous.get('status') == 'published':
        score = sanity.read(manifest['sanity']['score_id'])
        if identity(strip_system(score)) != previous.get('published_content_sha256'):
            raise ValueError('Recorded publication changed remotely; reconcile before reuse')
        for section in receipt['sections']:
            content = storage.read(section['storage_path'])
            if content is None or digest_bytes(content) != section['sha256']:
                raise ValueError('Published click content has changed')
        return dict(previous, status='already_published')
    # A timed-out mutation may have committed. Reconcile its exact expected
    # content before planning another write; never append the change twice.
    if previous and previous.get('expected_content_sha256'):
        current = sanity.read(manifest['sanity']['score_id'])
        if current['_rev'] != manifest['sanity']['revision']:
            if identity(strip_system(current)) != previous['expected_content_sha256']:
                raise ValueError('Uncertain publication conflicts with current Sanity content')
            for section in receipt['sections']:
                content = storage.read(section['storage_path'])
                if content is None or digest_bytes(content) != section['sha256']:
                    raise ValueError('Uncertain publication has mismatched click content')
            previous.update(status='published', published_revision=current['_rev'],
                            published_content_sha256=previous['expected_content_sha256'])
            write_json(journal_path, previous)
            return previous
    plan = delivery_plan(manifest, receipt, storage, sanity)
    if not apply:
        return dict(plan, status='preview', notes=manifest['delivery'].get('changes', []))
    notes = manifest['delivery'].get('changes')
    if not notes or any(not isinstance(note, str) or not note.strip() for note in notes):
        raise ValueError('Publication requires concise user-facing change notes in delivery.changes')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', manifest['sanity']['score_id']):
        raise ValueError('Unsafe canonical score ID')
    lock_path = '.gphil-autoplay-locks/' + manifest['sanity']['score_id'] + '.json'
    lock = json_bytes({'owner': uuid.uuid4().hex, 'evaluation_id': receipt['evaluation_id']})
    storage.write(lock_path, lock, replace=False)
    try:
        # Close the window between preview and acquiring the writer lock.
        locked_plan = delivery_plan(manifest, receipt, storage, sanity)
        if locked_plan != plan:
            raise ValueError('Remote objects changed since delivery preview')
        if previous:
            for old, new in zip(previous['objects'], plan['objects']):
                if old['path'] != new['path'] or new['before_sha256'] not in (old['before_sha256'], old['after_sha256']):
                    raise ValueError('Remote click changed outside this delivery journal')
        journal = previous or dict(plan, status='started', verified_paths=[])
        journal['status'] = 'uploading'
        write_json(journal_path, journal)
        changed_keys = {o['section'] for o in journal['objects'] if o['changed']}
        for obj in plan['objects']:
            current = storage.read(obj['path'])
            current_hash = digest_bytes(current) if current is not None else None
            if current_hash != obj['before_sha256']:
                raise ValueError('Concurrent click replacement detected: ' + obj['path'])
            if obj['changed']:
                changed_keys.add(obj['section'])
                data = Path(obj['local_path']).read_bytes()
                if digest_bytes(data) != obj['after_sha256']:
                    raise ValueError('Evaluated file changed during delivery')
                # Preserve previous bytes for recovery before replacing anything.
                if current is not None:
                    backup = journal_path.parent / 'remote-before' / obj['path']
                    backup.parent.mkdir(parents=True, exist_ok=True)
                    if not backup.exists():
                        backup.write_bytes(current)
                storage.write(obj['path'], data)
            downloaded = storage.read(obj['path'])
            if downloaded is None or digest_bytes(downloaded) != obj['after_sha256']:
                raise ValueError('Uploaded click readback mismatch: ' + obj['path'])
            if obj['path'] not in journal['verified_paths']:
                journal['verified_paths'].append(obj['path'])
            write_json(journal_path, journal)
        validate_receipt(receipt)
        before_score = sanity.read(manifest['sanity']['score_id'])
        movement = check_score(before_score, manifest['sanity'])
        for section in receipt['sections']:
            actual = keyed(movement['sections'], section['key'], 'section')
            if any(actual.get(k) != v for k, v in section.get('metadata', {}).items()):
                changed_keys.add(section['key'])
        changed = [s for s in receipt['sections'] if s['key'] in changed_keys]
        if not changed:
            journal['status'] = 'unchanged'
            write_json(journal_path, journal)
            return journal
        # Verify every object once more before announcing the score revision.
        for obj in plan['objects']:
            content = storage.read(obj['path'])
            if content is None or digest_bytes(content) != obj['after_sha256']:
                raise ValueError('Click content changed before metadata publication')
        now = datetime.now(timezone.utc).isoformat()
        entry = previous.get('changelog_entry') if previous else None
        entry = entry or {'_key': 'autoplay_' + receipt['evaluation_id'][:24],
                          '_type': 'scoreChangeEntry', 'date': now, 'revision': now,
                          'changeType': 'general', 'changes': notes}
        journal.update(status='publishing_metadata', changelog_entry=entry)
        write_json(journal_path, journal)
        expected = expected_score(before_score, manifest['sanity'], changed, entry)
        journal['expected_content_sha256'] = identity(strip_system(expected))
        write_json(journal_path, journal)
        sanity.patch(manifest['sanity']['score_id'], manifest['sanity']['revision'],
                     publication_values(before_score, manifest['sanity'], changed), entry)
        published = sanity.read(manifest['sanity']['score_id'])
        if strip_system(published) != strip_system(expected):
            raise ValueError('Sanity publication readback mismatch; preserve journal and reconcile')
        journal.update(status='published', published_revision=published['_rev'],
                       published_content_sha256=identity(strip_system(published)))
        write_json(journal_path, journal)
        return journal
    except Exception as error:
        if 'journal' in locals():
            journal['status'] = 'incomplete'
            journal['error'] = str(error)
            write_json(journal_path, journal)
        raise
    finally:
        if storage.read(lock_path) == lock:
            storage.delete(lock_path)
