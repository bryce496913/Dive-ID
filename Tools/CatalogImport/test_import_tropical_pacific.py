import importlib.util
import json
import copy
import tempfile
from unittest import mock
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "tropical_pacific_importer", Path(__file__).with_name("import_tropical_pacific.py")
)
IMPORTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IMPORTER)


class CategoryNormalizationTests(unittest.TestCase):
    def test_recognized_workbook_groups_map_to_fish(self):
        for value in ("Butterflyfishes", "Damselfishes", "  butterflyFISHES  "):
            self.assertEqual(IMPORTER.canonical_category(value), ("fish", ""))

    def test_legacy_fish_values_remain_supported(self):
        self.assertEqual(IMPORTER.canonical_category("fish"), ("fish", ""))
        self.assertEqual(IMPORTER.canonical_category(" FISHES "), ("fish", ""))

    def test_non_fish_names_are_not_matched_by_substring(self):
        for value in ("jellyfish", "cuttlefish", "starfish"):
            category, diagnostic = IMPORTER.canonical_category(value)
            self.assertIsNone(category)
            self.assertEqual(diagnostic, f"unrecognized workbook category: {value}")

    def test_unknown_value_has_review_diagnostic(self):
        self.assertEqual(
            IMPORTER.canonical_category("Mystery swimmers"),
            (None, "unrecognized workbook category: Mystery swimmers"),
        )

    def test_every_mapped_bundled_fish_retains_canonical_category(self):
        report = json.loads((ROOT / "Reports/TropicalPacificImportReport.json").read_text())
        profiles = json.loads((ROOT / "DiveID/Resources/IdentificationPacks/TropicalPacific/Creatures.json").read_text())
        profile_by_id = {profile["id"]: profile for profile in profiles}
        import csv
        with (ROOT / "Reports/TropicalPacificOutcomes.csv").open(newline="", encoding="utf-8") as handle:
            outcomes = list(csv.DictReader(handle))
        mapped_fish = [row for row in outcomes if row["outcome"] == "included" and row["canonical_category"] == "fish"]
        self.assertTrue(mapped_fish)
        self.assertTrue(all(profile_by_id[row["creature_id"]]["categories"] == ["fish"] for row in mapped_fish))
        self.assertEqual(report["outcomeCounts"], {"included": 384, "pendingReview": 1266, "excluded": 0})
        self.assertEqual(report["recordCounts"], {
            "structurallyIncluded": 384,
            "developmentSupplementIncluded": 616,
            "bundled": 1000,
            "humanReviewed": sum(p["review"]["status"] in ("sourceChecked", "verified") for p in profiles),
            "publicationEligible": sum(p["review"]["status"] == "verified" for p in profiles),
            "reviewQueue": 1650,
        })

    def test_suspect_omate_entry_remains_traceable_in_review_queue(self):
        import csv
        with (ROOT / "Reports/TropicalPacificReviewQueue.csv").open(newline="", encoding="utf-8") as handle:
            matches = [row for row in csv.DictReader(handle) if row["common_name"] == "Omate Angelfish"]
        self.assertEqual(len(matches), 1)
        self.assertEqual(matches[0]["creature_id"], "cc4394d7-ce81-515e-b22a-22d5892c0913")
        self.assertEqual(matches[0]["source_id"], "SRC-D04E0C28")
        self.assertEqual(matches[0]["source_book_page"], "39")


class DraftExpansionTests(unittest.TestCase):
    def setUp(self):
        self.additions = json.loads((ROOT / "Data/TropicalPacific/TropicalPacificExpansion616.draft.json").read_text())
        self.audit = json.loads((ROOT / "Data/TropicalPacific/TropicalPacificExpansion616.audit.json").read_text())
        self.bundled = json.loads((ROOT / "DiveID/Resources/IdentificationPacks/TropicalPacific/Creatures.json").read_text())
        ids = {p["id"] for p in self.additions}
        self.baseline = [p for p in self.bundled if p["id"] not in ids]

    def test_exact_records_provenance_and_order_are_preserved(self):
        merged = IMPORTER.merge_draft_expansion(self.baseline, self.additions, self.audit)
        self.assertEqual(len(self.baseline), 384)
        self.assertEqual(len(merged), 1000)
        self.assertEqual(merged, self.bundled)
        by_id = {p["id"]: p for p in merged}
        for record in self.additions:
            self.assertEqual(by_id[record["id"]], record)
            self.assertEqual(record["review"]["status"], "draft")
        self.assertEqual(merged, IMPORTER.merge_draft_expansion(self.baseline[::-1], self.additions[::-1], self.audit))

    def test_duplicate_uuid_and_identity_are_rejected(self):
        for field in ("id", "commonName", "scientificName"):
            with self.subTest(field=field):
                additions = copy.deepcopy(self.additions)
                additions[0][field] = self.baseline[0][field]
                with self.assertRaises(ValueError):
                    IMPORTER.merge_draft_expansion(self.baseline, additions, self.audit)
        additions = copy.deepcopy(self.additions)
        additions[0]["id"] = self.baseline[0]["id"].upper()
        with self.assertRaises(ValueError):
            IMPORTER.merge_draft_expansion(self.baseline, additions, self.audit)

    def test_invalid_supplement_leaves_existing_outputs_untouched(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            creatures, manifest = output / "Creatures.json", output / "PackManifest.json"
            creatures.write_bytes(b"original creatures")
            manifest.write_bytes(b"original manifest")
            additions = copy.deepcopy(self.additions)
            additions[0]["id"] = self.baseline[0]["id"]
            expansion = output / "invalid.json"
            expansion.write_text(json.dumps(additions))
            with mock.patch("sys.argv", ["import_tropical_pacific.py", "--output", str(output), "--expansion", str(expansion)]):
                with self.assertRaises(ValueError):
                    IMPORTER.main()
            self.assertEqual(creatures.read_bytes(), b"original creatures")
            self.assertEqual(manifest.read_bytes(), b"original manifest")

    def test_unapproved_input_and_audit_mismatch_fail_closed(self):
        for mutation in ("status", "count", "selection"):
            additions, audit = copy.deepcopy(self.additions), copy.deepcopy(self.audit)
            if mutation == "status":
                additions[0]["review"]["status"] = "verified"
            elif mutation == "count":
                audit["proposedDevelopmentTotal"] = 999
            else:
                audit["selectedRecordIDs"][0] = audit["selectedRecordIDs"][1]
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                IMPORTER.merge_draft_expansion(self.baseline, additions, audit)


if __name__ == "__main__":
    unittest.main()
