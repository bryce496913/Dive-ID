"""Tests for writing the draft records into the Global pack. Records are synthetic except the final check."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_global  # noqa: E402


def draft(record_id, similar=(), status="draft"):
    return {"id": record_id, "categories": ["fish"], "review": {"status": status},
            "similarSpecies": [{"speciesID": s, "reason": "similar"} for s in similar],
            "dataSources": [{"sourceName": "FishBase (v26.06)", "reviewedFields": ["summary", "similarSpecies"]}]}


class ComposeTests(unittest.TestCase):
    def test_excludes_records_missing_required_fields(self):
        records, excluded, _ = publish_global.compose([draft("a"), draft("b")], {"b": {"flags": ["missing_required:summary"]}, "a": {"flags": ["vocabulary:colors"]}})
        self.assertEqual(([r["id"] for r in records], excluded), (["a"], ["b"]))

    def test_drops_similar_species_outside_the_pack_and_their_reviewed_field(self):
        records, _, dropped = publish_global.compose([draft("a", ["b", "x"]), draft("b", ["a"]), draft("c", ["x", "c"])], {})
        self.assertEqual([[s["speciesID"] for s in r["similarSpecies"]] for r in records], [["b"], ["a"], []])
        self.assertEqual(dropped, 3)
        self.assertNotIn("similarSpecies", records[2]["dataSources"][0]["reviewedFields"])
        self.assertIn("similarSpecies", records[0]["dataSources"][0]["reviewedFields"])

    def test_does_not_mutate_the_staged_drafts(self):
        staged = [draft("a", ["x"])]
        publish_global.compose(staged, {})
        self.assertEqual(staged[0]["similarSpecies"][0]["speciesID"], "x")

    def test_refuses_anything_but_drafts_so_release_never_sees_the_pack(self):
        with self.assertRaises(SystemExit):
            publish_global.compose([draft("a", status="verified")], {})


class ManifestTests(unittest.TestCase):
    def test_counts_come_from_the_records(self):
        template = {"id": "global", "packVersion": 1, "speciesCount": 0, "regionAliases": []}
        manifest = publish_global.manifest_for([draft("a"), draft("b")], template)
        self.assertEqual((manifest["speciesCount"], manifest["includedRecordCount"], manifest["humanReviewedRecordCount"],
                          manifest["publicationEligibleRecordCount"], manifest["packVersion"]), (2, 2, 0, 0, publish_global.PACK_VERSION))
        self.assertEqual(manifest["regionAliases"], [])
        self.assertEqual(template["speciesCount"], 0, "the template is not modified")


class OutputTests(unittest.TestCase):
    def test_output_is_deterministic_and_unchanged_files_are_not_rewritten(self):
        text = publish_global.creatures_text([draft("a"), draft("b")])
        self.assertEqual(text, publish_global.creatures_text([draft("a"), draft("b")]))
        self.assertEqual(len(json.loads(text)), 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Creatures.json"
            self.assertEqual(publish_global.write_if_changed(path, text), "written")
            self.assertEqual(publish_global.write_if_changed(path, text), "unchanged")
            self.assertEqual(path.read_text(), text)
            self.assertEqual(list(Path(directory).iterdir()), [path], "no temporary file left behind")

    def test_committed_global_pack_matches_a_fresh_publish(self):
        staging = publish_global.REPO / "Data/GlobalMarine/FishBase"
        if not (staging / "RiskReport.json").exists():
            self.skipTest("staging data not present")
        drafts = [r for f in sorted((staging / "Drafts").glob("batch-*.json")) for r in json.loads(f.read_text())]
        records, _, _ = publish_global.compose(drafts, json.loads((staging / "RiskReport.json").read_text())["records"])
        self.assertEqual((publish_global.PACK / "Creatures.json").read_text(), publish_global.creatures_text(records))
        manifest = json.loads((publish_global.PACK / "PackManifest.json").read_text())
        self.assertEqual(manifest, publish_global.manifest_for(records, manifest))
        self.assertTrue(all(r["review"]["status"] == "draft" for r in records))


if __name__ == "__main__":
    unittest.main()
