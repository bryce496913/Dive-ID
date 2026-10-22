import copy
import json
import unittest
from publication_expectations import ROOT, approved_ids, approved_from_batches, generate, generate_archived
from test_catalog_review import record, decision_item, document, CATALOGUE, M


class PublicationExpectationsTests(unittest.TestCase):
    def test_checked_in_oracle_matches_all_current_valid_approvals(self):
        expected = json.loads((ROOT / 'DiveIDTests/Fixtures/PublicationApprovedIDs.json').read_text())
        self.assertEqual(generate(), expected)

    def test_archived_v3_packs_still_match_their_october_decisions(self):
        self.assertEqual(generate_archived(), {
            'caribbean': ['00000000-0000-0000-0000-000000000003', 'fc213eff-6ba6-53ab-b288-f6e654299e68'],
            'tropical-pacific': []})

    def test_mixed_pack_includes_every_approval_and_excludes_drafts(self):
        records = [record('one', 'One'), record('two', 'Two'), record('three', 'Three')]
        decisions = document(*(decision_item(r) for r in records[:2]))
        M.apply_decisions(records, decisions, CATALOGUE)
        self.assertEqual(approved_ids(records, decisions, CATALOGUE), sorted(r['id'] for r in records[:2]))

    def test_unapproved_status_and_changed_content_cannot_enter_oracle(self):
        original = record()
        decisions = document(decision_item(original))
        M.apply_decisions([original], decisions, CATALOGUE)
        with self.assertRaisesRegex(ValueError, 'differs from approvals'):
            approved_ids([original], document(), CATALOGUE)
        changed = copy.deepcopy(original)
        changed['summary'] = 'Materially changed after review'
        with self.assertRaisesRegex(ValueError, 'does not cover current content'):
            approved_ids([changed], decisions, CATALOGUE)


    def test_bundled_packs_oracle_comes_from_batch_approvals(self):
        import test_global_batches
        w = test_global_batches.Workspace()
        self.addCleanup(w.temp.cleanup)
        records = json.loads((w.pack / 'Creatures.json').read_text())
        self.assertEqual(approved_from_batches(records, w.root, validate=False), [], 'no decision, no approval')
        manifest = w.prepare(seed=3)[0]
        w.record(manifest)
        reviews, _ = w.approved()
        for r in records:
            if r['id'] in reviews:
                r['review'] = reviews[r['id']]
        self.assertEqual(approved_from_batches(records, w.root, validate=False), sorted(reviews))
        # A verified flag without a covering approval, or altered review evidence, is refused.
        forged = copy.deepcopy(records)
        unapproved = next(r for r in forged if r['id'] not in reviews)
        unapproved['review'] = dict(next(iter(reviews.values())))
        with self.assertRaisesRegex(ValueError, 'differs from approvals'):
            approved_from_batches(forged, w.root, validate=False)
        altered = copy.deepcopy(records)
        next(r for r in altered if r['id'] in reviews)['review']['verifiedBy'] = 'Someone else'
        with self.assertRaisesRegex(ValueError, 'Review evidence differs'):
            approved_from_batches(altered, w.root, validate=False)

if __name__ == '__main__':
    unittest.main()
