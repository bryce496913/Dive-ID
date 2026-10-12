import copy
import json
import unittest
from publication_expectations import ROOT, approved_ids, generate
from test_catalog_review import record, decision_item, document, CATALOGUE, M


class PublicationExpectationsTests(unittest.TestCase):
    def test_checked_in_oracle_matches_all_current_valid_approvals(self):
        expected = json.loads((ROOT / 'DiveIDTests/Fixtures/PublicationApprovedIDs.json').read_text())
        self.assertEqual(generate(), expected)

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


if __name__ == '__main__':
    unittest.main()
