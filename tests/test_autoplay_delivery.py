"""Behavioral checks for gated delivery, exact receipts and OPUS comparison."""
from copy import deepcopy
import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from autoplay_lib.delivery import deliver
from autoplay_lib.evaluate import compare_reference, native_export, validate_receipt
from autoplay_lib.opus import extract_clicks
from autoplay_lib.remote import Sanity, RemoteError, storage_path
from autoplay_lib.support import file_digest, identity, json_bytes


class FakeStorage:
    def __init__(self, objects):
        self.objects, self.writes, self.deletes = dict(objects), [], []
        self.corrupt_readback = False

    def read(self, path):
        value = self.objects.get(path)
        if self.corrupt_readback and path.endswith('a.json') and path in self.writes:
            return b'[]'
        return value

    def write(self, path, data, replace=True):
        if not replace and path in self.objects:
            raise RemoteError('Lock already exists')
        self.writes.append(path)
        self.objects[path] = data

    def delete(self, path):
        self.deletes.append(path)
        del self.objects[path]


class FakeSanity:
    def __init__(self):
        self.score = {'_id': 'score-1', '_type': 'score', '_rev': 'r1', 'slug': {'current': 'test'},
                      'private': True, 'unrelated': {'preserve': 42}, 'changelog': [],
                      'movements': [{'_key': 'm', 'index': 1, 'sections':
                                     [{'_key': 'a', 'name': 'A'}, {'_key': 'b', 'name': 'B'}]}]}
        self.patches, self.fail_patch = [], False

    def read(self, score_id):
        return deepcopy(self.score)

    def patch(self, score_id, revision, values, entry):
        if self.fail_patch:
            raise RemoteError('Simulated metadata failure')
        if revision != self.score['_rev']:
            raise RemoteError('Revision conflict')
        self.patches.append(values)
        for path, value in values.items():
            key = re.search(r'sections\[_key=="([^"]+)"\]', path)[1]
            row = next(s for s in self.score['movements'][0]['sections'] if s['_key'] == key)
            row[path.rsplit('.', 1)[1]] = value
        self.score['changelog'].append(entry)
        self.score['_rev'] = 'r2'


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.journal = root / 'delivery.json'
        self.manifest = {'sanity': {'score_id': 'score-1', 'revision': 'r1', 'movement_key': 'm', 'movement_index': 1},
                         'delivery': {'bucket': 'test', 'changes': ['Corrected click timing.']}}
        sections = []
        for key in ('a', 'b'):
            path = root / (key + '.json')
            path.write_bytes(json_bytes([{'time': 0, 'beat': 1}, {'time': 500, 'beat': 2}]))
            sections.append({'key': key, 'name': key, 'path': str(path), 'sha256': file_digest(path),
                             'storage_path': f'1/CLICKDATA/{key}.json', 'duration_seconds': 1,
                             'metadata': {}})
        self.receipt = {'schema': 1, 'status': 'evaluated', 'issues': [], 'fingerprints': {},
                        'sanity': self.manifest['sanity'], 'sections': sections}
        self.receipt['evaluation_id'] = identity(self.receipt)
        self.storage = FakeStorage({'1/CLICKDATA/b.json': Path(sections[1]['path']).read_bytes()})
        self.sanity = FakeSanity()

    def run_delivery(self, apply=False):
        return deliver(self.manifest, self.receipt, self.journal, storage=self.storage,
                       sanity=self.sanity, apply=apply)

    def test_preview_does_not_upload_or_mutate(self):
        result = self.run_delivery()
        self.assertEqual(result['status'], 'preview')
        self.assertEqual([o['changed'] for o in result['objects']], [True, False])
        self.assertEqual(self.storage.writes, [])
        self.assertEqual(self.sanity.patches, [])

    def test_publish_changes_only_affected_section_and_preserves_score(self):
        result = self.run_delivery(True)
        self.assertEqual(result['status'], 'published')
        sections = self.sanity.score['movements'][0]['sections']
        self.assertTrue(sections[0]['updateRequired'])
        self.assertNotIn('updateRequired', sections[1])
        self.assertEqual(self.sanity.score['unrelated'], {'preserve': 42})
        self.assertEqual(len(self.sanity.score['changelog']), 1)
        self.assertEqual(self.run_delivery(True)['status'], 'already_published')
        self.assertEqual(len(self.sanity.patches), 1)
        self.assertFalse(any('audio-manifest' in p for p in self.storage.writes))

    def test_upload_failure_never_publishes_and_retains_journal(self):
        self.storage.corrupt_readback = True
        with self.assertRaisesRegex(ValueError, 'readback mismatch'):
            self.run_delivery(True)
        self.assertFalse(self.sanity.patches)
        self.assertEqual(json.loads(self.journal.read_text())['status'], 'incomplete')
        self.assertFalse(any(p.startswith('.gphil-autoplay-locks') for p in self.storage.objects))

    def test_resume_after_metadata_failure_does_not_lose_refresh(self):
        self.sanity.fail_patch = True
        with self.assertRaises(RemoteError):
            self.run_delivery(True)
        self.sanity.fail_patch = False
        self.assertEqual(self.run_delivery(True)['status'], 'published')
        self.assertTrue(self.sanity.score['movements'][0]['sections'][0]['updateRequired'])
        self.assertEqual(self.storage.writes.count('1/CLICKDATA/a.json'), 1)

    def test_timeout_after_committed_metadata_is_reconciled_without_duplicate(self):
        original_patch = self.sanity.patch

        def committed_then_timeout(*args):
            original_patch(*args)
            raise RemoteError('Response lost after commit')

        self.sanity.patch = committed_then_timeout
        with self.assertRaises(RemoteError):
            self.run_delivery(True)
        self.sanity.patch = original_patch
        self.assertEqual(self.run_delivery(True)['status'], 'published')
        self.assertEqual(len(self.sanity.patches), 1)
        self.assertEqual(len(self.sanity.score['changelog']), 1)

    def test_revision_change_blocks_before_any_write(self):
        self.sanity.score['_rev'] = 'other'
        with self.assertRaisesRegex(ValueError, 'revision changed'):
            self.run_delivery(True)
        self.assertEqual(self.storage.writes, [])

    def test_stale_receipt_or_changed_output_blocks_before_remote_writes(self):
        self.receipt['sections'][0]['duration_seconds'] = 2
        with self.assertRaisesRegex(ValueError, 'receipt changed'):
            self.run_delivery(True)
        self.assertEqual(self.storage.writes, [])

    def test_lock_conflict_never_replaces_existing_lock(self):
        self.storage.objects['.gphil-autoplay-locks/score-1.json'] = b'other publisher'
        with self.assertRaisesRegex(RemoteError, 'Lock already exists'):
            self.run_delivery(True)
        self.assertEqual(self.sanity.patches, [])

    def test_delivery_bucket_is_bound_to_current_score(self):
        self.manifest['delivery']['bucket'] = 'other'
        with self.assertRaisesRegex(ValueError, 'bucket'):
            self.run_delivery(True)


class EvidenceTests(unittest.TestCase):
    def test_exact_discrepancy_approval_does_not_cover_new_drift(self):
        left = [{'time': 0, 'beat': 1}, {'time': 600, 'beat': 2}]
        right = [{'time': 0, 'beat': 1}, {'time': 500, 'beat': 2}]
        initial = compare_reference(left, right)
        self.assertFalse(initial['approved'])
        approval = {'approved_discrepancy_sha256': initial['discrepancy_sha256'], 'approval_note': 'Authored fermata'}
        self.assertTrue(compare_reference(left, right, approval)['approved'])
        left[1]['time'] = 650
        self.assertFalse(compare_reference(left, right, approval)['approved'])

    def test_comparison_settings_cannot_hide_a_mismatch_without_approval(self):
        left = [{'time': 0, 'beat': 1}, {'time': 600, 'beat': 2}]
        right = [{'time': 0, 'beat': 1}, {'time': 500, 'beat': 2}]
        with self.assertRaisesRegex(ValueError, 'windows are unsupported'):
            compare_reference(left, right, {'end_ms': 1})
        aligned = compare_reference(left, right, {'time_scale': 1.2})
        self.assertFalse(aligned['approved'])
        approved = {'time_scale': 1.2, 'approval_note': 'Measured render scale',
                    'approved_discrepancy_sha256': aligned['discrepancy_sha256']}
        self.assertTrue(compare_reference(left, right, approved)['approved'])
        approved['offset_ms'] = 1
        self.assertFalse(compare_reference(left, right, approved)['approved'])
        self.assertFalse(compare_reference(left, left, {'tolerance_ms': 20})['approved'])

    def test_default_mapping_hash_matches_explicit_equivalent_values(self):
        left = [{'time': 0, 'beat': 1}, {'time': 600, 'beat': 2}]
        right = [{'time': 0, 'beat': 1}, {'time': 500, 'beat': 2}]
        implicit = compare_reference(left, right)
        explicit = compare_reference(left, right, {'time_scale': 1, 'offset_ms': 0, 'tolerance_ms': 3.0})
        self.assertEqual(implicit['discrepancy_sha256'], explicit['discrepancy_sha256'])

    def test_decoder_uses_attack_onset_including_negative_lobe(self):
        samples = [0.] * 15000
        samples[0:4] = [-.03, -.08, .15, .5]
        samples[10000:10004] = [-.04, -.08, .08, .2]
        self.assertEqual(extract_clicks(samples, 10000), [{'time': 0, 'beat': 1}, {'time': 1000, 'beat': 2}])

    def test_saved_native_receipt_required(self):
        with tempfile.TemporaryDirectory() as folder:
            for altered in ({'savedOnly': False}, {'dirtyAfter': True}, {'stateChangeCountAfter': 2}):
                result = dict(project=folder, savedOnly=True, dirtyBefore=False, dirtyAfter=False,
                              stateChangeCountBefore=1, stateChangeCountAfter=1)
                result.update(altered)
                with self.assertRaises((ValueError, RuntimeError)):
                    native_export(Path(folder), Path(folder), lambda *args: {'ok': True, 'result': result})

    def test_already_open_clean_tab_is_not_saved_file_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            result = dict(project=folder, savedOnly=True, dirtyBefore=False, dirtyAfter=False,
                          stateChangeCountBefore=1, stateChangeCountAfter=1,
                          openedOwnTab=False, exporterVersion='gphil-native-click-export/2')
            with self.assertRaisesRegex(ValueError, 'already open'):
                native_export(Path(folder), Path(folder), lambda *args: {'ok': True, 'result': result})

    def test_path_traversal_refused(self):
        for path in ('../x.json', '/x.json', '1//x.json', '1/./x.json', '1\\x.json'):
            with self.assertRaises(ValueError):
                storage_path(path)

    def test_sanity_draft_refusal(self):
        def transport(*args, **kwargs):
            return json.dumps({'result': [{'_id': 'score'}, {'_id': 'drafts.score'}]}).encode()
        client = Sanity({'project_id': 'example', 'dataset': 'production'}, {'SANITY_READ_TOKEN': 'test'}, transport)
        with self.assertRaisesRegex(ValueError, 'draft'):
            client.read('score')


if __name__ == '__main__':
    unittest.main()
