import copy
import importlib.util
import json
import os
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest import mock

SPEC = importlib.util.spec_from_file_location("catalog_review", Path(__file__).with_name("catalog_review.py"))
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

CATALOGUE = "test-pack"


def record(species_id="stable", name="Name"):
    stable_id = str(uuid.uuid5(uuid.NAMESPACE_URL, "https://dive-id.test/" + species_id))
    return {
        "id": stable_id, "commonName": name, "scientificName": "Species " + species_id, "categories": ["fish"],
        "summary": "text", "distinguishingFeatures": ["trait"], "typicalHabitat": "reef", "geographicRange": "test range",
        "dataSources": [{"stableSourceID": "source-1", "sourceName": "Test source", "sourceURL": "https://example.test/species",
                         "citationReference": "p. 1", "reviewedFields": ["identity"]}],
        "review": {"status": "draft"},
    }


def decision_item(r, **overrides):
    item = {
        "speciesID": r["id"], "sourceIdentity": [list(value) for value in M.source_identity(r)],
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
        self.assertIn(f"decision[2] duplicates speciesID {current['id']!r} from decision[1]", str(raised.exception))

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
        valid = decision_item(first)
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
        item = decision_item(target, corrections={"summary": "corrected"})
        corrected = copy.deepcopy(target)
        corrected["summary"] = "corrected"
        item["reviewedContentFingerprint"] = M.content_fingerprint(corrected)
        M.apply_decisions([target, unrelated], document(item), CATALOGUE)
        self.assertEqual(target["id"], record("one")["id"])
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
            decisions.write_text(json.dumps(document(decision_item(records[0]),
                                                        decision_item(records[1], speciesID="unknown"))))
            before = (creatures.read_bytes(), pack_manifest.read_bytes())
            with mock.patch("sys.argv", ["catalog_review.py", "--pack", str(root), "--decisions", str(decisions)]):
                with self.assertRaises(M.DecisionValidationError):
                    M.main()
            self.assertEqual((creatures.read_bytes(), pack_manifest.read_bytes()), before)

    def test_valid_correction_then_invalid_record_in_other_pack_position_leaves_files_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            records = [record("one", "One"), record("two", "Two")]
            manifest = {"id": CATALOGUE, "schemaVersion": 1, "packVersion": 1,
                        "displayName": "Test", "shortDescription": "Test pack", "geographicScope": "Test",
                        "regionAliases": [], "speciesCount": 2, "speciesResourceName": "Creatures",
                        "imageSubdirectory": "Images", "includedWithApp": True, "lastDataReviewDate": None,
                        "includedRecordCount": 2, "humanReviewedRecordCount": 0,
                        "publicationEligibleRecordCount": 0}
            first_corrected = copy.deepcopy(records[0]); first_corrected["summary"] = "valid correction"
            second_corrected = copy.deepcopy(records[1]); second_corrected["categories"] = "fish"
            items = [decision_item(records[0], corrections={"summary": "valid correction"}, reviewedContentFingerprint=M.content_fingerprint(first_corrected)),
                     decision_item(records[1], corrections={"categories": "fish"}, reviewedContentFingerprint=M.content_fingerprint(second_corrected))]
            creatures, pack_manifest, decisions = root / "Creatures.json", root / "PackManifest.json", root / "decisions.json"
            creatures.write_text(json.dumps(records)); pack_manifest.write_text(json.dumps(manifest)); decisions.write_text(json.dumps(document(*items)))
            before = creatures.read_bytes(), pack_manifest.read_bytes()
            with mock.patch("sys.argv", ["catalog_review.py", "--pack", str(root), "--decisions", str(decisions)]):
                with self.assertRaisesRegex(M.DecisionValidationError, r"speciesID .*categories.*array of strings"):
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

    def test_swift_compatibility_rejections_are_diagnostic_and_transactional(self):
        fixture = json.loads((Path(__file__).parents[2] / "DiveIDTests/Fixtures/CatalogueValidationCases.json").read_text())
        for case in fixture["invalid"]:
            with self.subTest(case=case["name"]):
                current = copy.deepcopy(fixture["validRecord"])
                before = copy.deepcopy(current)
                corrected = copy.deepcopy(current)
                corrected[case["field"]] = case["value"]
                item = decision_item(current, corrections={case["field"]: case["value"]})
                item["reviewedContentFingerprint"] = M.content_fingerprint(corrected)
                with self.assertRaises(M.DecisionValidationError) as raised:
                    M.apply_decisions([current], document(item), CATALOGUE)
                message = str(raised.exception)
                self.assertIn(current["id"], message)
                self.assertIn(case["diagnosticPath"], message)
                self.assertEqual(current, before)

    def test_string_array_element_type_is_not_coerced(self):
        current = record()
        corrected = copy.deepcopy(current); corrected["categories"] = ["fish", 7]
        item = decision_item(current, corrections={"categories": ["fish", 7]}, reviewedContentFingerprint=M.content_fingerprint(corrected))
        with self.assertRaisesRegex(M.DecisionValidationError, r"categories\[1\].*expected string.*int 7"):
            M.apply_decisions([current], document(item), CATALOGUE)


if __name__ == "__main__":
    unittest.main()
