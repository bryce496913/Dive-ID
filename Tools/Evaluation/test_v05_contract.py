import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class V05ContractTests(unittest.TestCase):
    def test_frozen_versions_match_their_digests_and_source_ids(self):
        for version in (1, 2):
            raw = (ROOT / f'DiveIDTests/Fixtures/V05Development.v{version}.json').read_bytes()
            fixture = json.loads(raw)
            protocol = json.loads((ROOT / f'Data/Evaluation/V05Protocol.v{version}.json').read_text())
            self.assertEqual(hashlib.sha256(raw).hexdigest(), protocol['fixtureSHA256'])
            evidence = {e['id']:e for e in fixture['evidence']}
            self.assertEqual(len(fixture['cases']), 46)
            self.assertEqual(len(evidence), 17)
            for case in fixture['cases']:
                self.assertTrue(case['provenance'].startswith('synthetic-'))
                self.assertLessEqual(case['maximumConfidence'], 1)
                if case['kind'] == 'identification':
                    support = {evidence[e]['speciesID'] for e in case['evidenceIDs']}
                    self.assertTrue(set(case['expectedSpeciesIDs']).issubset(support))
                    self.assertTrue(all(evidence[e]['references'] for e in case['evidenceIDs']))
                    self.assertIn(case['maximumAcceptableRank'], (3, 10))

    def test_v2_erratum_changes_no_descriptions_bounds_or_thresholds(self):
        old = json.loads((ROOT / 'DiveIDTests/Fixtures/V05Development.v1.json').read_text())
        new = json.loads((ROOT / 'DiveIDTests/Fixtures/V05Development.v2.json').read_text())
        changed = []
        for before, after in zip(old['cases'], new['cases']):
            if before != after:
                changed.append(before['id'])
                self.assertEqual({k:v for k,v in before.items() if k not in ('selectedPackID','expectedSpeciesIDs')},
                                 {k:v for k,v in after.items() if k not in ('selectedPackID','expectedSpeciesIDs')})
                self.assertEqual(after['selectedPackID'], 'caribbean')
                self.assertEqual(after['expectedSpeciesIDs'], ['00000000-0000-0000-0000-000000000010'])
        self.assertEqual(changed, ['v05-08-diagnostic','v05-08-paraphrase'])
        protocols = [json.loads((ROOT / f'Data/Evaluation/V05Protocol.v{v}.json').read_text()) for v in (1,2)]
        self.assertEqual(protocols[0]['minimumRates'], protocols[1]['minimumRates'])

    def test_collection_template_contains_no_tuning_examples(self):
        text = (ROOT / 'Data/Evaluation/IndependentDiverCollection.md').read_text()
        self.assertIn('No observations have been collected yet.', text)
        self.assertIn('tuningAccessGranted (false)', text)

if __name__ == '__main__':
    unittest.main()
