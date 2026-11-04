"""build_independent_source contracts. Synthetic payloads and a synthetic catalogue only:
these are not diver accounts, identities or verification evidence."""
import csv
import io
import json
import tempfile
import unittest
import uuid
from contextlib import redirect_stdout
from pathlib import Path

import build_independent_source as b
import import_feedback as m
import independent_divers as d
from test_import_feedback import CLAIMED_SPECIES, RULES, SHOWN_SPECIES, export, record

SPECIES_A, SPECIES_B = str(uuid.UUID(int=501)), str(uuid.UUID(int=502))
CATALOGUE = {SPECIES_A: 'synthetica alpha', SPECIES_B: 'synthetica beta'}


class BuildIndependentSourceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.holdout = self.root / 'holdout'
        self.repo = self.root / 'repo'
        self.repo.mkdir()

    def imported(self, *records):
        path = self.root / 'export.json'
        path.write_text(json.dumps(export(*records)))
        m.run([path], self.holdout, RULES, root=self.repo)

    def curate(self, **by_number):
        """Fill worksheet rows: by_number maps 'r<n>' to the curator's column values."""
        path = self.holdout / 'curator-worksheet.csv'
        rows = list(csv.DictReader(io.StringIO(path.read_text())))
        for row in rows:
            row.update(by_number.get('r' + str(uuid.UUID(row['feedbackID'])).replace('-', '').lstrip('0'), {}))
        out = io.StringIO()
        writer = csv.DictWriter(out, fieldnames=m.WORKSHEET_COLUMNS, lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)
        path.write_text(out.getvalue())

    def build(self, pilot=True):
        return b.build(self.holdout, 'synthetic-v1', pilot, catalogue=CATALOGUE, root=self.repo)

    def source(self):
        return json.loads((self.holdout / 'source.json').read_text())

    @staticmethod
    def verified(**changes):
        row = {'language': 'en', 'attestsOwnUnpromptedWords': 'yes', 'labelKind': 'identification',
               'expectedSpeciesIDs': SPECIES_A, 'scientificNames': 'Synthetica alpha', 'curatorID': 'CURATOR-SYNTH',
               'adjudicationDate': '2026-10-30', 'verifiedWithoutAppResults': 'yes', 'notes': 'synthetic rationale',
               'evidenceReferences': 'synthetic-photo-1; synthetic-guide-p12'}
        row.update(changes)
        return row

    def test_builds_a_source_the_existing_freeze_validator_accepts(self):
        self.imported(record(1), record(2), record(3), record(4))
        self.curate(r1=self.verified(),
                    r2=self.verified(labelKind='ambiguous', expectedSpeciesIDs=SPECIES_A, acceptableSpeciesIDs=SPECIES_B,
                                     scientificNames='Synthetica alpha; Synthetica beta'),
                    r3=self.verified(labelKind='unresolved', expectedSpeciesIDs='', scientificNames='Synthetica gamma',
                                     outOfCatalogue='yes', notes='verified species, not in the catalogue'),
                    r4=self.verified(labelKind='', expectedSpeciesIDs='', scientificNames=''))
        counts = self.build()
        self.assertEqual((counts['inSource'], counts['identifiable'], counts['ambiguous'], counts['unresolved'], counts['outOfCatalogue']),
                         (4, 1, 1, 2, 1))
        document = self.source()
        cases = d.validate(document)
        self.assertEqual([c['kind'] for c in cases], ['identification', 'ambiguous', 'unresolved', 'unresolved'])
        self.assertEqual(cases[1]['expectedSpeciesIDs'], [SPECIES_A, SPECIES_B])
        self.assertTrue(all(c['split'] == 'development' for c in cases), 'the pilot is development material')
        report = d.pilot_readiness(document)
        self.assertEqual((report['outOfCatalogueLabels'], report['labelKinds']['ambiguous']), (1, 1))

    def test_wording_is_verbatim_and_claims_never_become_labels(self):
        self.imported(record(1))
        self.curate(r1=self.verified())
        self.build()
        row = self.source()['observations'][0]
        self.assertEqual(row['description'], '  SYNTHETIC 1: flat fish, blue spots  ')
        self.assertEqual(row['observationID'], str(uuid.UUID(int=1)), 'the feedbackID is the stable observation ID')
        self.assertEqual(row['label']['acceptableSpeciesIDs'], [SPECIES_A])
        self.assertNotIn(CLAIMED_SPECIES, json.dumps(row['label']))
        self.assertNotIn(SHOWN_SPECIES, json.dumps(row['label']))
        self.assertTrue(row['contributorClaimedIdentity']['engineExposed'], 'kept as private provenance only')
        self.assertEqual(row['observationContext']['broadRegion'], 'Synthetic Sea')

    def test_an_edited_worksheet_description_stops_the_build(self):
        self.imported(record(1))
        self.curate(r1=self.verified(description='SYNTHETIC 1: flat fish, blue spots'))
        with self.assertRaisesRegex(b.BuildError, 'differs from the stored wording'):
            self.build()
        self.assertFalse((self.holdout / 'source.json').exists())

    def test_species_ids_must_exist_and_match_the_scientific_name(self):
        self.imported(record(1))
        self.curate(r1=self.verified(scientificNames='Synthetica beta'))
        with self.assertRaisesRegex(b.BuildError, 'do not match'):
            self.build()
        self.curate(r1=self.verified(expectedSpeciesIDs=str(uuid.UUID(int=999))))
        with self.assertRaisesRegex(b.BuildError, 'not in the Global catalogue'):
            self.build()

    def test_out_of_catalogue_stays_unresolved_and_must_really_be_absent(self):
        self.imported(record(1))
        self.curate(r1=self.verified(labelKind='noMatch', expectedSpeciesIDs='', outOfCatalogue='yes', scientificNames='Synthetica gamma'))
        with self.assertRaisesRegex(b.BuildError, 'labelKind unresolved'):
            self.build()
        self.curate(r1=self.verified(labelKind='unresolved', expectedSpeciesIDs='', outOfCatalogue='yes', scientificNames='Synthetica alpha'))
        with self.assertRaisesRegex(b.BuildError, 'is in the catalogue'):
            self.build()

    def test_rows_without_attestation_or_english_are_left_out_and_counted(self):
        self.imported(record(1), record(2), record(3))
        self.curate(r1=self.verified(), r2=self.verified(attestsOwnUnpromptedWords='no'), r3=self.verified(language=''))
        counts = self.build()
        self.assertEqual(counts['inSource'], 1)
        self.assertEqual(sum(counts['excluded'].values()), 2)

    def test_without_pilot_the_curator_declares_development_use(self):
        self.imported(record(1))
        self.curate(r1=self.verified(usedForDevelopment='maybe'))
        with self.assertRaisesRegex(b.BuildError, 'usedForDevelopment'):
            self.build(pilot=False)
        self.curate(r1=self.verified(usedForDevelopment='no'))
        self.build(pilot=False)
        self.assertFalse(self.source()['observations'][0]['usedForDevelopment'])

    def test_cli_prints_counts_only(self):
        self.imported(record(1))
        self.curate(r1=self.verified())
        original = b.load_catalogue
        b.load_catalogue = lambda: CATALOGUE
        self.addCleanup(setattr, b, 'load_catalogue', original)
        out = io.StringIO()
        with redirect_stdout(out):
            status = b.main(['--holdout', str(self.holdout), '--dataset-version', 'synthetic-v1', '--pilot'])
        self.assertEqual(status, 0)
        self.assertNotIn('SYNTHETIC', out.getvalue())
        self.assertNotIn(SPECIES_A, out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['identifiable'], 1)

    def test_the_real_catalogue_loads_scientific_names(self):
        catalogue = b.load_catalogue()
        self.assertEqual(len(catalogue), 4798)
        self.assertTrue(all(name and name == name.casefold() for name in catalogue.values()))


if __name__ == '__main__':
    unittest.main()
