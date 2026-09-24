import copy
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("catalog_review", Path(__file__).with_name("catalog_review.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

CATALOGUE = "test-pack"


def record(species_id="stable", name="Name"):
    return {
        "id": species_id, "commonName": name, "scientificName": "Species name", "categories": ["fish"],
        "summary": "text", "distinguishingFeatures": ["trait"],
        "dataSources": [{"stableSourceID": "source-1", "sourceURL": "https://example.test/species",
                         "citationReference": "p. 1", "reviewedFields": ["identity"]}],
        "review": {"status": "draft"},
    }


def decision_item(r, **overrides):
    item = {
        "speciesID": r["id"], "sourceIdentity": [["source-1", "p. 1"]],
        "reviewedContentFingerprint": M.content_fingerprint(r), "corrections": {}, "decision": "verified",
        "reviewerIdentity": "Reviewer", "reviewDate": "2026-09-24T00:00:00Z",
        "reviewerNotes": "Source checked", "unresolvedQuestions": [],
    }
    item.update(overrides)
    return item


def document(*items, catalogue=CATALOGUE):
    return {"schemaVersion": 1, "catalogueID": catalogue, "decisions": list(items)}


class ReviewTests(unittest.TestCase):
    def test_decision_survives_regeneration(self):
        first = record()
        overlay = document(decision_item(first))
        self.assertEqual(M.apply_decisions([first], overlay, CATALOGUE)[0]["state"], "applied")
        regenerated = record()
        self.assertEqual(M.apply_decisions([regenerated], overlay, CATALOGUE)[0]["state"], "applied")
        self.assertEqual(regenerated["review"]["status"], "verified")

    def test_material_change_makes_decision_stale(self):
        original = record()
        changed = copy.deepcopy(original)
        changed["summary"] = "changed"
        result = M.apply_decisions([changed], document(decision_item(original)), CATALOGUE)[0]
        self.assertEqual(result["state"], "stale")
        self.assertEqual(changed["review"]["status"], "draft")

    def test_unresolved_category_blocks_approval(self):
        current = record()
        current["categories"] = []
        item = decision_item(current, unresolvedQuestions=["category needs source page"])
        self.assertEqual(M.apply_decisions([current], document(item), CATALOGUE)[0]["state"], "blocked")
        self.assertEqual(current["review"]["status"], "draft")

    def test_duplicate_decisions_identify_both_entries_even_when_identical(self):
        current = record()
        item = decision_item(current)
        with self.assertRaises(M.DecisionValidationError) as raised:
            M.apply_decisions([current], document(item, copy.deepcopy(item)), CATALOGUE)
        self.assertIn("decision[2] duplicates speciesID 'stable' from decision[1]", str(raised.exception))

    def test_verified_reviewer_and_notes_reject_missing_or_whitespace(self):
        for field, value in (("reviewerIdentity", None), ("reviewerIdentity", "  \n"),
                             ("reviewerNotes", None), ("reviewerNotes", " \t")):
            with self.subTest(field=field, value=value):
                current = record()
                with self.assertRaises(M.DecisionValidationError) as raised:
                    M.apply_decisions([current], document(decision_item(current, **{field: value})), CATALOGUE)
                self.assertIn(field, str(raised.exception))
                self.assertEqual(current["review"]["status"], "draft")

    def test_verified_date_rejects_missing_format_and_impossible_dates(self):
        for value in (None, "2026-09-24", "2026-99-24T00:00:00Z", "2026-09-24T00:00:00+00:00"):
            with self.subTest(value=value):
                current = record()
                with self.assertRaisesRegex(M.DecisionValidationError, "YYYY-MM-DDTHH:MM:SSZ"):
                    M.apply_decisions([current], document(decision_item(current, reviewDate=value)), CATALOGUE)

    def test_unsupported_status_unknown_species_and_wrong_catalogue_are_diagnostic(self):
        current = record()
        bad = decision_item(current, speciesID="missing", decision="approved")
        with self.assertRaises(M.DecisionValidationError) as raised:
            M.apply_decisions([current], document(bad, catalogue="other-pack"), CATALOGUE)
        message = str(raised.exception)
        self.assertIn("does not match target catalogue", message)
        self.assertIn("unknown speciesID 'missing'", message)
        self.assertIn("'approved' is unsupported", message)

    def test_ambiguous_catalogue_species_id_is_rejected(self):
        records = [record(), record()]
        with self.assertRaisesRegex(M.DecisionValidationError, r"ambiguous; catalogue records \[1, 2\]"):
            M.apply_decisions(records, document(decision_item(records[0])), CATALOGUE)

    def test_valid_then_invalid_decision_changes_no_record(self):
        first, second = record("one", "One"), record("two", "Two")
        before = copy.deepcopy([first, second])
        valid = decision_item(first, speciesID="one")
        invalid = decision_item(second, speciesID="unknown", reviewerNotes=" ")
        with self.assertRaises(M.DecisionValidationError):
            M.apply_decisions([first, second], document(valid, invalid), CATALOGUE)
        self.assertEqual([first, second], before)

    def test_verified_requires_source_evidence_swift_will_accept(self):
        current = record()
        current["dataSources"][0]["reviewedFields"] = []
        item = decision_item(current)
        with self.assertRaisesRegex(M.DecisionValidationError, "required by Swift validation"):
            M.apply_decisions([current], document(item), CATALOGUE)

    def test_valid_update_preserves_ids_and_unrelated_records(self):
        target, unrelated = record("one", "One"), record("two", "Two")
        unrelated_before = copy.deepcopy(unrelated)
        item = decision_item(target, speciesID="one", corrections={"summary": "corrected"})
        corrected = copy.deepcopy(target)
        corrected["summary"] = "corrected"
        item["reviewedContentFingerprint"] = M.content_fingerprint(corrected)
        M.apply_decisions([target, unrelated], document(item), CATALOGUE)
        self.assertEqual(target["id"], "one")
        self.assertEqual(target["summary"], "corrected")
        self.assertEqual(unrelated, unrelated_before)

    def test_invalid_overlay_leaves_both_catalogue_files_byte_identical(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = [record("one", "One"), record("two", "Two")]
            manifest = {"id": CATALOGUE, "speciesCount": 2}
            creatures = root / "Creatures.json"
            pack_manifest = root / "PackManifest.json"
            decisions = root / "decisions.json"
            creatures.write_text(json.dumps(records))
            pack_manifest.write_text(json.dumps(manifest))
            decisions.write_text(json.dumps(document(decision_item(records[0], speciesID="one"),
                                                        decision_item(records[1], speciesID="unknown"))))
            before = (creatures.read_bytes(), pack_manifest.read_bytes())
            with mock.patch("sys.argv", ["catalog_review.py", "--pack", str(root), "--decisions", str(decisions)]):
                with self.assertRaises(M.DecisionValidationError):
                    M.main()
            self.assertEqual((creatures.read_bytes(), pack_manifest.read_bytes()), before)

    def test_second_output_replace_failure_rolls_back_both_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            creatures = root / "Creatures.json"
            manifest = root / "PackManifest.json"
            creatures.write_bytes(b"old creatures\n")
            manifest.write_bytes(b"old manifest\n")
            before = (creatures.read_bytes(), manifest.read_bytes())
            real_replace = os.replace
            calls = 0

            def fail_fourth_replace(source, target):
                nonlocal calls
                calls += 1
                if calls == 4:
                    raise OSError("simulated manifest replacement failure")
                return real_replace(source, target)

            with mock.patch.object(M.os, "replace", side_effect=fail_fourth_replace):
                with self.assertRaisesRegex(OSError, "simulated"):
                    M.replace_catalogue_pair(creatures, manifest, [record()], {"id": CATALOGUE})
            self.assertEqual((creatures.read_bytes(), manifest.read_bytes()), before)
            self.assertEqual(list(root.glob(".catalog-review-*")), [])


if __name__ == "__main__":
    unittest.main()
