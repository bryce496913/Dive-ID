"""Tests for writing the draft records into the Global pack. Records are synthetic except the final check."""
import json
import os
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_global  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "CatalogReview"))


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


class CaribbeanCarryTests(unittest.TestCase):
    def test_caribbean_records_are_carried_unchanged_as_drafts(self):
        regional = dict(draft("car-1", ["car-2"]), commonName="Queen Angelfish", bundledImage={"fileName": "car-1.svg"},
                        review={"status": "verified", "verifiedBy": "Bryce", "reviewDate": "2026-10-12", "reviewerNotes": "approved"})
        carried = publish_global.carried_caribbean([draft("fb-1")], [regional, draft("car-2")])
        self.assertEqual([r["id"] for r in carried], ["car-1", "car-2"])
        self.assertEqual(carried[0]["review"], publish_global.CARIBBEAN_REVIEW, "a regional approval does not carry over")
        self.assertIsNone(carried[0]["bundledImage"], "artwork stays in the Caribbean pack")
        self.assertEqual({k: v for k, v in carried[0].items() if k not in ("review", "bundledImage")},
                         {k: v for k, v in regional.items() if k not in ("review", "bundledImage")})
        self.assertEqual(regional["review"]["status"], "verified", "the regional record is not modified")
        records, _, _ = publish_global.compose([draft("fb-1", ["car-1"])] + carried, {})
        self.assertEqual([s["speciesID"] for s in records[0]["similarSpecies"]], ["car-1"], "references into the carried records resolve")

    def test_a_caribbean_species_built_from_fishbase_is_refused(self):
        with self.assertRaises(SystemExit):
            publish_global.carried_caribbean([draft("car-1")], [draft("car-1")])


class ManifestTests(unittest.TestCase):
    def test_counts_come_from_the_records(self):
        template = {"id": "global", "packVersion": 1, "speciesCount": 0, "regionAliases": []}
        manifest = publish_global.manifest_for([draft("a"), draft("b")], template)
        self.assertEqual((manifest["speciesCount"], manifest["includedRecordCount"], manifest["humanReviewedRecordCount"],
                          manifest["publicationEligibleRecordCount"], manifest["packVersion"]), (2, 2, 0, 0, publish_global.PACK_VERSION))
        self.assertEqual(manifest["regionAliases"], [])
        self.assertEqual(manifest["displayName"], "Global")
        self.assertIn("0 of 2 records approved", manifest["shortDescription"])
        self.assertEqual(template["speciesCount"], 0, "the template is not modified")

    def test_named_global_while_drafts_remain(self):
        approved = dict(draft("a"), review={"status": "verified"})
        partial = publish_global.manifest_for([approved, draft("b")], {"id": "global"}, 1)
        self.assertEqual((partial["displayName"], partial["publicationEligibleRecordCount"], partial["packVersion"]),
                         ("Global", 1, publish_global.PACK_VERSION + 1))
        self.assertIn("1 of 2 records approved", partial["shortDescription"])
        complete = publish_global.manifest_for([approved, dict(approved, id="b")], {"id": "global"}, 2)
        self.assertEqual(complete["displayName"], "Global")
        self.assertEqual(complete["shortDescription"], "Worldwide catalogue from FishBase and SeaLifeBase")


class OutputTests(unittest.TestCase):
    def test_output_is_deterministic_and_unchanged_files_are_not_rewritten(self):
        text = publish_global.creatures_text([draft("a"), draft("b")])
        self.assertEqual(text, publish_global.creatures_text([draft("a"), draft("b")]))
        self.assertEqual(len(json.loads(text)), 2)
        with tempfile.TemporaryDirectory() as directory:
            pack = Path(directory)
            self.assertEqual(publish_global.write_pack(pack, text, "{}\n"), "written")
            self.assertEqual(publish_global.write_pack(pack, text, "{}\n"), "unchanged")
            self.assertEqual(((pack / "Creatures.json").read_text(), (pack / "PackManifest.json").read_text()), (text, "{}\n"))
            self.assertEqual(sorted(p.name for p in pack.iterdir()), ["Creatures.json", "PackManifest.json"], "no staging left behind")

    def test_a_failed_second_replacement_restores_both_files_to_their_original_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            pack = Path(directory)
            (pack / "Creatures.json").write_bytes(b"[old creatures]\n")
            (pack / "PackManifest.json").write_bytes(b"{old manifest}\n")
            real_replace, calls = os.replace, []

            def fail_manifest_install(source, target):
                calls.append((Path(source).name, Path(target).name))
                # Two backups, then Creatures.json is installed; installing the manifest fails.
                if len(calls) == 4:
                    raise OSError("simulated manifest replacement failure")
                return real_replace(source, target)

            with mock.patch.object(os, "replace", side_effect=fail_manifest_install):
                with self.assertRaisesRegex(OSError, "simulated"):
                    publish_global.write_pack(pack, "[new creatures]\n", "{new manifest}\n")
            self.assertEqual(calls[3], ("PackManifest.json", "PackManifest.json"))
            self.assertEqual((pack / "Creatures.json").read_bytes(), b"[old creatures]\n")
            self.assertEqual((pack / "PackManifest.json").read_bytes(), b"{old manifest}\n")
            self.assertEqual(sorted(p.name for p in pack.iterdir()), ["Creatures.json", "PackManifest.json"])

    def test_committed_global_pack_matches_a_fresh_publish(self):
        staging = publish_global.REPO / "Data/GlobalMarine/FishBase"
        if not (staging / "RiskReport.json").exists():
            self.skipTest("staging data not present")
        drafts = [r for f in sorted((staging / "Drafts").glob("batch-*.json")) for r in json.loads(f.read_text())]
        caribbean = json.loads(publish_global.CARIBBEAN.read_text())
        drafts += publish_global.carried_caribbean(drafts, caribbean)
        records, _, _ = publish_global.compose(drafts, json.loads((staging / "RiskReport.json").read_text())["records"])
        reviews, report = publish_global.apply_reviews(records, publish_global.global_batches.BATCHES)
        photo_batches = publish_global.photo_batches
        photo_files, _ = publish_global.apply_photos(records, photo_batches.PHOTO_MANIFEST, photo_batches.THUMBNAILS, photo_batches.BATCHES)
        # The Caribbean species are the regional pack's own records, last, with only the review changed.
        tail = records[-len(caribbean):]
        self.assertEqual([r["id"] for r in tail], [r["id"] for r in caribbean])
        for carried, regional in zip(tail, caribbean):
            ignored = ("review", "bundledImage", "similarSpecies", "dataSources")
            self.assertEqual({k: v for k, v in carried.items() if k not in ignored}, {k: v for k, v in regional.items() if k not in ignored})
            self.assertEqual(carried["bundledImage"] is not None, f"{carried['id'].lower()}-inat-" in " ".join(photo_files),
                             "only an approved photo is bundled")
            self.assertEqual(carried["review"]["status"], "verified" if carried["id"] in reviews else "draft")
        self.assertEqual((publish_global.PACK / "Creatures.json").read_text(), publish_global.creatures_text(records))
        images = publish_global.PACK / "Images"
        self.assertEqual(sorted(p.name for p in images.glob("*-inat-*.jpg")) if images.exists() else [], sorted(photo_files))
        manifest = json.loads((publish_global.PACK / "PackManifest.json").read_text())
        self.assertEqual(manifest, publish_global.manifest_for(records, manifest, report["approvalsRecorded"]))
        applied = publish_global.global_batches.BATCHES / "AppliedApprovals.json"
        self.assertEqual(applied.read_text(), publish_global.applied_approvals_text(reviews, report), "AppliedApprovals.json is current")
        # A stale record's old approval no longer applies; it is verified only when a current
        # approval covers its new content (as batch-18-rereview does for Graceful and Silky shark).
        stale = set(report["staleRecords"])
        self.assertTrue(all(r["review"]["status"] == ("verified" if r["id"] in reviews else "draft")
                            for r in records if r["id"] in stale), "changed content keeps no approval")
        verified = {r["id"] for r in records if r["review"]["status"] == "verified"}
        self.assertEqual(verified, set(reviews), "only records an approval covers are verified")
        self.assertTrue(all(r["review"]["status"] == "draft" for r in records if r["id"] not in verified))


class BatchReviewTests(unittest.TestCase):
    def test_only_records_a_current_approval_covers_become_verified_and_counted(self):
        import test_global_batches
        w = test_global_batches.Workspace()
        self.addCleanup(w.temp.cleanup)
        manifest = w.prepare(seed=7)[0]
        stale = [e["speciesID"] for e in manifest["records"] if e["selection"] == "unread"][0]
        w.record(manifest)
        next(r for r in w.records if r["id"] == stale)["summary"] = "Changed after approval."
        reviews, report = publish_global.apply_reviews(w.records, w.root)
        verified = {r["id"] for r in w.records if r["review"]["status"] == "verified"}
        self.assertEqual(len(verified), 79)
        self.assertNotIn(stale, verified)
        self.assertEqual(report["staleRecords"], [stale])
        self.assertEqual(publish_global.manifest_for(w.records, {"id": "global"})["publicationEligibleRecordCount"], 79)

    def test_a_new_generation_of_an_approved_batch_never_lowers_the_pack_version(self):
        import test_global_batches
        w = test_global_batches.Workspace()
        self.addCleanup(w.temp.cleanup)
        w.record(w.prepare(seed=7)[0])
        _, report = publish_global.apply_reviews(w.records, w.root)
        version = publish_global.manifest_for(w.records, {"id": "global"}, report["approvalsRecorded"])["packVersion"]
        w.prepare(force_new=True)  # supersedes the approved generation; nothing is approved now
        reviews, report = publish_global.apply_reviews(w.records, w.root)
        self.assertEqual((reviews, report["approvedBatches"], report["approvalsRecorded"]), ({}, [], 1))
        self.assertEqual(publish_global.manifest_for(w.records, {"id": "global"}, report["approvalsRecorded"])["packVersion"], version)


if __name__ == "__main__":
    unittest.main()
