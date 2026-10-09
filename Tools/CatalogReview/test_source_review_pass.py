import copy
import json
import unittest
from pathlib import Path
from unittest.mock import patch

from catalog_review import content_fingerprint
from regenerate_caribbean import generate
from prepare_source_review_pass import generate as packets

ROOT = Path(__file__).resolve().parents[2]


class SourceReviewPassTests(unittest.TestCase):
    def test_caribbean_overlay_regenerates_exact_bundle_and_preserves_provenance(self):
        records, manifest, outcomes = generate()
        baseline = json.loads((ROOT / 'Data/CatalogReview/CaribbeanSourceBaseline.json').read_text())
        bundled = json.loads((ROOT / 'DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json').read_text())
        self.assertEqual(records, bundled)
        self.assertEqual(manifest, json.loads((ROOT / 'DiveID/Resources/IdentificationPacks/Caribbean/PackManifest.json').read_text()))
        self.assertEqual([r['id'] for r in records], [r['id'] for r in baseline])
        for before, after in zip(baseline, records):
            for source in before['dataSources']:
                self.assertIn(source, after['dataSources'])
        self.assertTrue(all(o['state'] == 'applied' for o in outcomes))

    def test_stale_overlay_stops_generation(self):
        import regenerate_caribbean
        real_apply = regenerate_caribbean.apply_decisions
        def stale(records, decisions, catalogue):
            decisions = copy.deepcopy(decisions)
            decisions['decisions'][0]['reviewedContentFingerprint'] = 'sha256:' + '0' * 64
            return real_apply(records, decisions, catalogue)
        with patch.object(regenerate_caribbean, 'apply_decisions', side_effect=stale):
            with self.assertRaisesRegex(ValueError, 'Stale or blocked'):
                generate()

    def test_packets_bind_current_content_without_inventing_human_decisions(self):
        report = packets()
        self.assertEqual(report, json.loads((ROOT / 'Reports/CatalogueSourceReviewPass.json').read_text()))
        self.assertEqual(len(report['records']), 4)
        for packet in report['records']:
            self.assertEqual(packet['reviewedContentFingerprint'], content_fingerprint(packet['currentContent']))
            self.assertTrue(packet['references'])
            self.assertEqual(set(packet['fieldEvidence']), {'identity', 'structuredTraits', 'measurements', 'habitat', 'range'})
            self.assertIsNone(packet['humanDecisionRequired']['reviewerIdentity'])
            self.assertIsNone(packet['humanDecisionRequired']['reviewDate'])
            self.assertIsNone(packet['humanDecisionRequired']['decision'])


if __name__ == '__main__':
    unittest.main()
