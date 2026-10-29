"""import_feedback contracts. Synthetic payloads only; these are not diver accounts."""
import csv
import io
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path

import import_feedback as m

RULES = m.load_rules()
SHOWN_SPECIES = str(uuid.UUID(int=900))
CLAIMED_SPECIES = str(uuid.UUID(int=901))


def record(n, **changes):
    row = {
        'feedbackID': str(uuid.UUID(int=n)), 'attemptID': str(uuid.UUID(int=1000 + n)), 'createdAt': '2026-10-28T12:00:00Z',
        'updatedAt': '2026-10-28T12:00:00Z', 'appVersion': '0.5', 'appBuild': '3', 'buildChannel': 'release',
        'packID': 'global', 'catalogueVersion': 25, 'participantCode': 'DIVER-SYNTH001',
        'originalDescription': f'  SYNTHETIC {n}: flat fish, blue spots  ', 'firstSearchOfInstall': True,
        'editedAfterSeeingResults': False, 'shownResults': [{'rank': 1, 'speciesID': SHOWN_SPECIES}],
        'answer': 'claimedSpecies', 'claimedSpeciesID': CLAIMED_SPECIES, 'broadRegion': 'Synthetic Sea',
        'approximateDepth': {'value': 12, 'unit': 'metres'}, 'uncertainty': 'SYNTHETIC tail unclear',
        'hasPhotoToSend': True, 'consentForEvaluation': True, 'consentForPublication': False, 'priorExposure': False,
    }
    row.update(changes)
    return row


def export(*records):
    return {'schemaVersion': 1, 'format': 'diveid-diver-feedback', 'exportedAt': '2026-10-28T12:30:00Z',
            'participantCode': 'DIVER-SYNTH001', 'note': 'synthetic', 'records': list(records)}


class ImportFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.holdout = self.root / 'holdout'
        self.repo = self.root / 'repo'
        self.repo.mkdir()

    def write(self, name, document):
        path = self.root / name
        path.write_text(json.dumps(document) if not isinstance(document, str) else document)
        return path

    def run_import(self, *files):
        return m.run(list(files), self.holdout, RULES, root=self.repo)

    def stored(self):
        return json.loads((self.holdout / 'submissions.json').read_text())['submissions']

    def log(self):
        return json.loads((self.holdout / 'intake-log.json').read_text())['entries']

    def test_rejects_records_without_evaluation_consent(self):
        counts = self.run_import(self.write('a.json', export(record(1), record(2, consentForEvaluation=False))))
        self.assertEqual((counts['imported'], counts['rejected']), (1, 1))
        self.assertEqual([r['feedbackID'] for r in self.stored()], [str(uuid.UUID(int=1))])
        self.assertIn('no evaluation consent', [e['reason'] for e in self.log()])

    def test_photo_searches_never_qualify(self):
        photo = record(2, source='photo', recognizerID='stub-deterministic', recognizerVersion='1')
        counts = self.run_import(self.write('a.json', export(record(1, source='description'), photo)))
        self.assertEqual((counts['imported'], counts['rejected']), (1, 1))
        self.assertIn('photo search, not a description', [e['reason'] for e in self.log()])

    def test_rejects_edited_researches_and_later_searches(self):
        first = record(1)
        cases = [
            record(2, researchOfAttemptID=first['attemptID'], editedAfterSeeingResults=True, firstSearchOfInstall=False, priorExposure=True),
            record(3, researchOfAttemptID=first['attemptID'], editedAfterSeeingResults=False),  # unedited re-search
            record(4, firstSearchOfInstall=False, priorExposure=True),
            record(5, packID='tropical-atlantic'),
        ]
        counts = self.run_import(self.write('a.json', export(first, *cases)))
        self.assertEqual((counts['imported'], counts['rejected']), (1, 4))
        reasons = {e['feedbackID']: e['reason'] for e in self.log()}
        self.assertEqual(reasons[cases[1]['feedbackID']], 're-search or edited after results were shown')
        self.assertIn('prior exposure', reasons[cases[0]['feedbackID']])
        self.assertIn('not global', reasons[cases[3]['feedbackID']])

    def test_none_and_not_sure_are_kept_and_the_claim_is_never_a_label(self):
        counts = self.run_import(self.write('a.json', export(
            record(1, answer='none', claimedSpeciesID=None), record(2, answer='notSure', claimedSpeciesID=None), record(3))))
        self.assertEqual(counts['imported'], 3, 'no record is chosen by the diver\'s answer')
        rows = {r['feedbackID']: r for r in self.stored()}
        claimed = rows[str(uuid.UUID(int=3))]
        self.assertEqual(claimed['contributorClaimedIdentity'],
                         {'answer': 'claimedSpecies', 'claimedSpeciesID': CLAIMED_SPECIES, 'engineExposed': True, 'useAsLabel': False})
        self.assertNotIn('label', claimed)
        self.assertNotIn('expectedSpeciesIDs', claimed)
        self.assertEqual(claimed['description'], '  SYNTHETIC 3: flat fish, blue spots  ', 'verbatim, untrimmed')

    def test_worksheet_has_no_engine_output_or_claims(self):
        self.run_import(self.write('a.json', export(record(1), record(2, answer='none', claimedSpeciesID=None))))
        text = (self.holdout / 'curator-worksheet.csv').read_text()
        rows = list(csv.DictReader(io.StringIO(text)))
        self.assertEqual(list(rows[0]), m.WORKSHEET_COLUMNS)
        for leaked in (SHOWN_SPECIES, CLAIMED_SPECIES, 'claimedSpecies', 'notSure', 'shownResults', 'rank', 'catalogueVersion'):
            self.assertNotIn(leaked, text)
        self.assertEqual(rows[0]['description'], '  SYNTHETIC 1: flat fish, blue spots  ')
        self.assertEqual((rows[0]['broadRegion'], rows[0]['approximateDepth'], rows[0]['hasPhotoToSend']), ('Synthetic Sea', '12 metres', 'yes'))
        self.assertEqual(rows[0]['expectedSpeciesIDs'], '', 'left for the curator')

    def test_duplicate_files_and_records_import_once(self):
        file = self.write('a.json', export(record(1), record(2)))
        copy = self.write('b.json', export(record(2), record(3)))
        first = self.run_import(file, file, copy)
        self.assertEqual((first['imported'], first['duplicates']), (3, 3))
        again = self.run_import(file)
        self.assertEqual((again['imported'], again['duplicates'], again['inHoldout']), (0, 2, 3))
        self.assertEqual(len({r['feedbackID'] for r in self.stored()}), 3)

    def test_invalid_files_import_nothing(self):
        broken = record(2)
        del broken['originalDescription']
        bad = [self.write('bad1.json', '{not json'), self.write('bad2.json', {**export(record(1)), 'format': 'other'}),
               self.write('bad3.json', export(record(1), broken)),
               self.write('bad4.json', export(record(1, answer='claimedSpecies', claimedSpeciesID=None)))]
        counts = self.run_import(*bad)
        self.assertEqual((counts['invalidFiles'], counts['imported']), (4, 0))
        self.assertEqual(self.stored(), [])
        self.assertTrue(all('reason' in e for e in self.log()))

    def test_holdout_is_private_and_outside_the_repository(self):
        with self.assertRaisesRegex(m.ImportError_, 'outside the repository'):
            m.run([], self.repo / 'holdout', RULES, root=self.repo)
        self.run_import(self.write('a.json', export(record(1))))
        self.assertEqual(self.holdout.stat().st_mode & 0o777, 0o700)
        for name in ('submissions.json', 'intake-log.json', 'curator-worksheet.csv'):
            self.assertEqual((self.holdout / name).stat().st_mode & 0o777, 0o600, name)
        log_text = (self.holdout / 'intake-log.json').read_text()
        self.assertNotIn('SYNTHETIC 1', log_text, 'the log never copies descriptions')

    def test_cli_prints_counts_only(self):
        file = self.write('a.json', export(record(1)))
        out = io.StringIO()
        from contextlib import redirect_stdout
        with redirect_stdout(out):  # the holdout is in a temporary directory, outside the repository
            status = m.main(['--holdout', str(self.holdout), str(file)])
        self.assertEqual(status, 0)
        self.assertNotIn('SYNTHETIC', out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['imported'], 1)


if __name__ == '__main__':
    unittest.main()
