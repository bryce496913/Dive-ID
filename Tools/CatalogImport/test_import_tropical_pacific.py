import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main()
