"""Offline filesystem integration tests: no real taxonomy requests or app writes."""
import copy
import hashlib
import io
from contextlib import redirect_stdout
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import intake as intake_module
import process
from intake import InputSnapshot, SUPPLEMENT, WORKBOOK, INPUT_SCHEMA, fingerprint, intake, atomic_json
from process import load_results, generate


class CheckpointInputTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.original = InputSnapshot(intake_module.ROOT)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name, content in self.original.content.items():
            if content is not None:
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
        self.checkpoints = self.root / 'checkpoints'
        self.baseline = self.root / 'baseline'
        self.output = self.root / 'output'
        self.reports = self.root / 'reports'
        self.manifest = InputSnapshot(self.root).manifest

    def checkpoint(self, directory=None, manifest=None):
        path = (directory or self.checkpoints) / 'primary-01.json'
        manifest = manifest or self.manifest
        atomic_json(path, {'schemaVersion': INPUT_SCHEMA, 'inputManifest': manifest,
                           'inputFingerprint': fingerprint(manifest), 'queue': 'primary', 'batch': 1,
                           'results': [{'candidateID': 'probe', 'status': 'pending'}]})
        return path

    def test_unchanged_inputs_and_metadata_only_changes_allow_resume(self):
        self.checkpoint()
        for name in self.original.content:
            path = self.root / name
            if path.exists():
                os.utime(path, (100, 200))
        report = intake(self.root)[3]
        self.assertEqual(report['inputManifest'], self.manifest)
        self.assertEqual(load_results(self.checkpoints, report['inputManifest'])['probe']['status'], 'pending')

    def test_actual_offline_process_writes_accounted_checkpoint_and_resumes(self):
        args = ['process.py', '--batch', '1', '--resume', '--offline-cache-only',
                '--checkpoints', str(self.checkpoints), '--baseline-checkpoints', str(self.baseline),
                '--cache', str(self.root / 'cache'), '--output', str(self.output), '--report', str(self.reports)]
        data = intake(self.root)
        with patch.object(process, 'intake', return_value=data), patch('sys.argv', args), redirect_stdout(io.StringIO()):
            process.main()
            path = self.checkpoints / 'primary-01.json'
            before = path.read_bytes()
            document = json.loads(before)
            self.assertEqual(document['schemaVersion'], INPUT_SCHEMA)
            self.assertEqual(document['inputManifest'], self.manifest)
            self.assertEqual(len(document['results']), 250)
            process.main()
            self.assertEqual(path.read_bytes(), before)

    def test_accepted_name_change_in_app_pack_invalidates_checkpoint(self):
        self.checkpoint()
        name = next(p for p in self.original.pack_paths if p.endswith('/Creatures.json'))
        path = self.root / name
        profiles = json.loads(path.read_bytes())
        profiles[0]['taxonomy'] = {**(profiles[0].get('taxonomy') or {}), 'acceptedScientificName': 'Example changedacceptedname'}
        path.write_text(json.dumps(profiles))
        *_, report, names = intake(self.root)
        self.assertIn('example changedacceptedname', names)
        with self.assertRaisesRegex(ValueError, name):
            load_results(self.checkpoints, report['inputManifest'])

    def test_supplement_identity_change_invalidates_checkpoint(self):
        self.checkpoint()
        path = self.root / SUPPLEMENT
        profiles = json.loads(path.read_bytes())
        profiles[0]['scientificName'] = 'Example changedidentity'
        path.write_text(json.dumps(profiles))
        *_, report, names = intake(self.root)
        self.assertIn('example changedidentity', names)
        with self.assertRaisesRegex(ValueError, SUPPLEMENT):
            load_results(self.checkpoints, report['inputManifest'])

    def test_other_identity_and_decision_inputs_invalidate_checkpoint(self):
        self.checkpoint()
        names = [WORKBOOK, *self.original.pack_paths,
                 'Data/GlobalMarine/Expansion4000_CandidateQueue.csv',
                 'Data/GlobalMarine/Expansion4000_ReserveQueue.csv',
                 'Data/GlobalMarine/Expansion4000_Audit.json',
                 'Data/GlobalMarine/Sources/reef.csv', 'Data/GlobalMarine/Sources/asfis.csv']
        for name in names:
            with self.subTest(name=name):
                path = self.root / name
                before = path.read_bytes()
                path.write_bytes(before + b'\n')
                with self.assertRaisesRegex(ValueError, name):
                    load_results(self.checkpoints, InputSnapshot(self.root).manifest)
                path.write_bytes(before)

    def test_optional_supplement_absence_appearance_removal_and_replacement(self):
        path = self.root / SUPPLEMENT
        before = path.read_bytes()
        path.unlink()
        absent = intake(self.root)[3]['inputManifest']
        self.assertIsNone(absent['files'][SUPPLEMENT])
        checkpoint = self.checkpoint(manifest=absent)
        self.assertIn('probe', load_results(self.checkpoints, InputSnapshot(self.root).manifest))
        path.write_bytes(before)
        with self.assertRaisesRegex(ValueError, SUPPLEMENT):
            load_results(self.checkpoints, InputSnapshot(self.root).manifest)
        checkpoint.unlink()
        self.checkpoint()
        # An inode/path replacement with identical bytes is compatible.
        path.unlink()
        path.write_bytes(before)
        self.assertIn('probe', load_results(self.checkpoints, InputSnapshot(self.root).manifest))
        path.unlink()
        with self.assertRaisesRegex(ValueError, SUPPLEMENT):
            load_results(self.checkpoints, InputSnapshot(self.root).manifest)

    def test_optional_pack_membership_appearance_and_removal(self):
        path = self.root / 'DiveID/Resources/IdentificationPacks/Temporary/Creatures.json'
        self.checkpoint()
        path.parent.mkdir(parents=True)
        path.write_text('[]')
        appeared = InputSnapshot(self.root).manifest
        with self.assertRaisesRegex(ValueError, 'Temporary/Creatures.json'):
            load_results(self.checkpoints, appeared)
        self.checkpoint(manifest=appeared)
        path.unlink()
        with self.assertRaisesRegex(ValueError, 'Temporary/Creatures.json'):
            load_results(self.checkpoints, InputSnapshot(self.root).manifest)

    def test_discovery_and_dictionary_order_are_irrelevant(self):
        original_glob = Path.glob
        with patch.object(Path, 'glob', lambda path, pattern: iter(reversed(list(original_glob(path, pattern))))):
            reordered = InputSnapshot(self.root).manifest
        self.assertEqual(reordered, self.manifest)
        reordered['files'] = dict(reversed(list(reordered['files'].items())))
        reordered['configuration'] = dict(reversed(list(reordered['configuration'].items())))
        self.assertEqual(fingerprint(reordered), fingerprint(self.manifest))
        self.checkpoint(manifest=reordered)
        self.assertIn('probe', load_results(self.checkpoints, self.manifest))

    def test_missing_required_input_fails_before_checkpoint_changes(self):
        checkpoint = self.checkpoint()
        before = checkpoint.read_bytes()
        (self.root / WORKBOOK).unlink()
        with self.assertRaisesRegex(ValueError, 'missing: ' + WORKBOOK):
            intake(self.root)
        self.assertEqual(checkpoint.read_bytes(), before)

    def test_policy_configuration_changes_are_incompatible(self):
        self.checkpoint()
        with patch.object(intake_module, 'DECISION_POLICY', 999):
            changed = InputSnapshot(self.root).manifest
        with self.assertRaisesRegex(ValueError, 'configuration/decisionPolicyVersion'):
            load_results(self.checkpoints, changed)

    def test_intake_hashes_exactly_the_bytes_it_parsed(self):
        original_read = Path.read_bytes
        reads = {}
        def replacing_read(path):
            data = original_read(path)
            name = path.relative_to(self.root).as_posix()
            reads[name] = reads.get(name, 0) + 1
            if name == SUPPLEMENT:
                profiles = json.loads(data)
                profiles[0]['scientificName'] = 'Example aftersnapshot'
                path.write_text(json.dumps(profiles))
            if name == WORKBOOK:
                path.write_bytes(b'No longer a workbook')
            return data
        with patch.object(Path, 'read_bytes', replacing_read):
            _, _, _, report, names = intake(self.root)
        self.assertNotIn('example aftersnapshot', names)
        self.assertEqual(report['inputManifest'], self.manifest)
        self.assertTrue(all(count == 1 for count in reads.values()))
        self.assertNotEqual(report['inputSHA256'][SUPPLEMENT], hashlib.sha256((self.root / SUPPLEMENT).read_bytes()).hexdigest())

    def test_legacy_and_incomplete_accounting_rejected_without_relabeling(self):
        path = self.checkpoints / 'primary-01.json'
        for document in [
            {'schemaVersion': 1, 'inputFingerprint': fingerprint(self.manifest), 'results': []},
            {'schemaVersion': INPUT_SCHEMA, 'inputFingerprint': fingerprint(self.manifest), 'results': []},
        ]:
            atomic_json(path, document)
            before = path.read_bytes()
            with self.assertRaisesRegex(ValueError, 'legacy/missing input accounting'):
                load_results(self.checkpoints, self.manifest)
            self.assertEqual(path.read_bytes(), before)
        incomplete = copy.deepcopy(self.manifest)
        del incomplete['files'][SUPPLEMENT]
        self.checkpoint(manifest=incomplete)
        with self.assertRaisesRegex(ValueError, SUPPLEMENT):
            load_results(self.checkpoints, self.manifest)

    def test_rejection_precedes_all_checkpoint_cache_and_output_writes(self):
        # Even a stale NON-selected baseline store must reject a primary run
        # before the first per-candidate checkpoint or cache operation.
        self.checkpoint()
        self.checkpoint(self.baseline)
        data = intake(self.root)
        for directory in (self.output, self.reports):
            directory.mkdir()
            (directory / 'existing.txt').write_bytes(b'preserve me')
        def files():
            return {p.relative_to(self.root).as_posix(): p.read_bytes()
                    for d in (self.checkpoints, self.baseline, self.output, self.reports)
                    for p in d.rglob('*') if p.is_file()}
        manifest = copy.deepcopy(self.manifest)
        manifest['configuration']['decisionPolicyVersion'] = 999
        self.checkpoint(self.baseline, manifest)
        before = files()
        args = ['process.py', '--batch', '1', '--resume', '--offline-cache-only',
                '--checkpoints', str(self.checkpoints), '--baseline-checkpoints', str(self.baseline),
                '--cache', str(self.root / 'cache'), '--output', str(self.output), '--report', str(self.reports)]
        with patch.object(process, 'intake', return_value=data), patch('sys.argv', args), patch.object(process, 'Cache') as cache:
            with self.assertRaisesRegex(ValueError, 'decisionPolicyVersion'):
                process.main()
            cache.assert_not_called()
        self.assertEqual(files(), before)
        self.assertFalse((self.root / 'cache').exists())
        with self.assertRaisesRegex(ValueError, 'decisionPolicyVersion'):
            generate(self.root, *data[:4], data[4], self.checkpoints, self.baseline, self.output, self.reports)
        self.assertEqual(files(), before)


if __name__ == '__main__':
    unittest.main()
