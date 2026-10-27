"""Photo review batches and what reaches the pack: only photos a current decision approves."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "FishBaseIntake"))
import photo_batches as pb  # noqa: E402
import publish_global  # noqa: E402
from global_batches import ReviewError  # noqa: E402

SPECIES = ("00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000005")


def photo(species_id, number, rank, creator="Jane Diver"):
    return {"photoID": f"inaturalist:photo:{number}", "speciesID": species_id, "rank": rank,
            "commonName": f"Fish {species_id[-1]}", "scientificName": f"Genus s{species_id[-1]}",
            "photoURL": f"https://inaturalist-open-data.s3.amazonaws.com/photos/{number}/large.jpg",
            "sourcePageURL": f"https://www.inaturalist.org/photos/{number}", "sourceName": "iNaturalist",
            "observationID": f"inaturalist:observation:{number}", "observationURL": f"https://www.inaturalist.org/observations/{number}",
            "taxonID": "inaturalist:taxon:1", "creatorName": creator, "licenceCode": "cc-by-nc", "licenseName": "CC BY-NC 4.0",
            "licenseURL": "https://creativecommons.org/licenses/by-nc/4.0/", "retrievedOn": "2026-10-27",
            "observedOn": "2024-05-01", "review": {"status": "pending"}}


class Workspace:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.batches, self.pages, self.thumbs, self.pack = root / "batches", root / "pages", root / "thumbs", root / "pack"
        self.manifest = root / "PhotoManifest.json"
        self.photos = [photo(SPECIES[0], 11, 1), photo(SPECIES[0], 12, 2), photo(SPECIES[1], 21, 1)]
        self.write_photos()
        self.thumbs.mkdir()
        index = {}
        for p in self.photos:
            name = f"{p['speciesID']}-inat-{p['photoID'].rsplit(':', 1)[1]}.jpg"
            data = f"jpeg {name}".encode()
            (self.thumbs / name).write_bytes(data)
            index[p["photoID"]] = {"fileName": name, "speciesID": p["speciesID"], "sha256": pb.canonical_sha256({"d": data.decode()}),
                                   "bytes": len(data), "width": 400, "height": 300}
        (self.thumbs / "Thumbnails.json").write_text(json.dumps(index))
        self.pack.mkdir()
        self.records = [{"id": s, "commonName": f"Fish {s[-1]}", "scientificName": f"Genus s{s[-1]}",
                         "distinguishingFeatures": ["Bright blue body with a yellow tail spine"], "colors": ["blue"], "markings": []}
                        for s in SPECIES]
        (self.pack / "Creatures.json").write_text(json.dumps(self.records))

    def write_photos(self):
        self.manifest.write_text(json.dumps({"schemaVersion": 1, "photos": self.photos}))

    def prepare(self, batch="caribbean-8", species=SPECIES, photo_ids=None):
        return pb.prepare(batch, species, root=self.batches, pages=self.pages, photo_manifest=self.manifest,
                          thumbnails=self.thumbs, pack=self.pack, photo_ids=photo_ids)

    def record(self, key, outcome="approve", **kw):
        return pb.record(key, "Bryce", "I approve these photos.", outcome, review_date="2026-10-28", root=self.batches, commit="abc", **kw)

    def publish(self):
        records = json.loads(json.dumps(self.records))
        files, report = publish_global.apply_photos(records, self.manifest, self.thumbs, self.batches)
        return records, files, report


class PhotoBatchTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.tmp.cleanup)

    def test_prepare_writes_a_hashed_manifest_and_a_page_with_each_photo_beside_its_species(self):
        path, page, manifest = self.w.prepare()
        self.assertEqual(json.loads(path.read_text())["manifestSHA256"], pb.manifest_hash(manifest))
        self.assertEqual([p["photoID"] for p in manifest["photos"]], ["inaturalist:photo:11", "inaturalist:photo:12", "inaturalist:photo:21"])
        text = page.read_text()
        for needle in ("Fish 3", "Genus s3", "Bright blue body with a yellow tail spine", "Jane Diver", "CC BY-NC 4.0",
                       "../thumbs/00000000-0000-0000-0000-000000000003-inat-11.jpg", manifest["manifestSHA256"]):
            self.assertIn(needle, text)
        self.assertEqual(self.w.prepare()[2]["generation"], 2)

    def test_prepare_needs_thumbnails_and_known_species(self):
        with self.assertRaisesRegex(ReviewError, "no selected photo"):
            self.w.prepare(species=["00000000-0000-0000-0000-000000000099"])
        (self.w.thumbs / "Thumbnails.json").write_text("{}")
        with self.assertRaisesRegex(ReviewError, "make thumbnails first"):
            self.w.prepare()

    def test_a_batch_can_be_limited_to_the_photos_the_reviewer_saw(self):
        key = self.w.prepare(photo_ids=["inaturalist:photo:11", "inaturalist:photo:21"])[2]["manifestSHA256"]
        self.w.record(key)
        records, files, report = self.w.publish()
        self.assertEqual(report["approvedPhotos"], 2, "the unseen second photo stays unreviewed")
        self.assertEqual(sorted(files), [f"{SPECIES[0]}-inat-11.jpg", f"{SPECIES[1]}-inat-21.jpg"])
        with self.assertRaisesRegex(ReviewError, "not a selected photo"):
            self.w.prepare(photo_ids=["inaturalist:photo:99"])

    def test_nothing_is_approved_without_a_recorded_decision(self):
        self.w.prepare()
        records, files, report = self.w.publish()
        self.assertEqual((files, report["approvedPhotos"]), ({}, 0))
        self.assertTrue(all(r.get("bundledImage") is None for r in records))

    def test_record_requires_the_reviewer_and_their_own_words(self):
        key = self.w.prepare()[2]["manifestSHA256"]
        for kwargs in ({"reviewer": ""}, {"decision_text": " "}, {"outcome": "maybe"}):
            args = {"manifest_sha256": key, "reviewer": "Bryce", "decision_text": "Approved.", "outcome": "approve", **kwargs}
            with self.assertRaises(ReviewError):
                pb.record(root=self.w.batches, commit="abc", **args)
        with self.assertRaisesRegex(ReviewError, "needs --reason"):
            self.w.record(key, outcome="reject")
        with self.assertRaisesRegex(ReviewError, "not in this batch"):
            self.w.record(key, rejects=["inaturalist:photo:99=wrong fish"])

    def test_only_approved_photos_reach_the_pack_and_rejected_ones_never_do(self):
        key = self.w.prepare()[2]["manifestSHA256"]
        _, overlay = self.w.record(key, rejects=["inaturalist:photo:11=a juvenile, not the adult colours"])
        self.assertEqual(overlay["verbatimDecision"], "I approve these photos.")
        records, files, report = self.w.publish()
        images = {r["id"]: r.get("bundledImage") for r in records}
        self.assertEqual(images[SPECIES[0]]["photoID"], "inaturalist:photo:12", "the next approved photo is used")
        self.assertEqual(images[SPECIES[1]]["photoID"], "inaturalist:photo:21")
        self.assertNotIn(f"{SPECIES[0]}-inat-11.jpg", files)
        image = images[SPECIES[1]]
        self.assertEqual((image["creatorName"], image["licenseName"], image["sourceURL"], image["retrievedDate"]),
                         ("Jane Diver", "CC BY-NC 4.0", "https://www.inaturalist.org/photos/21", "2026-10-27"))
        self.assertEqual(image["alternativeText"], "Photo of Fish 5 (Genus s5): Bright blue body with a yellow tail spine.")

    def test_a_rejected_batch_approves_nothing(self):
        key = self.w.prepare()[2]["manifestSHA256"]
        self.w.record(key, outcome="reject", reason="photos too dark")
        self.assertEqual(self.w.publish()[1], {})

    def test_an_approval_lapses_when_the_photo_changes_or_the_batch_is_regenerated(self):
        key = self.w.prepare()[2]["manifestSHA256"]
        self.w.record(key)
        self.assertEqual(len(self.w.publish()[1]), 2)
        self.w.photos[2]["creatorName"] = "Someone Else"
        self.w.write_photos()
        _, files, report = self.w.publish()
        self.assertEqual((sorted(files), report["stalePhotos"]), ([f"{SPECIES[0]}-inat-11.jpg"], ["inaturalist:photo:21"]))
        self.w.photos[2]["creatorName"] = "Jane Diver"
        self.w.write_photos()
        self.w.prepare()
        _, files, report = self.w.publish()
        self.assertEqual((files, report["supersededDecisions"]), ({}, ["caribbean-8-g1"]), "a newer generation awaits its own decision")
        undecided = self.w.prepare()[2]["manifestSHA256"]
        self.w.prepare()
        with self.assertRaisesRegex(ReviewError, "superseded"):
            self.w.record(undecided)

    def test_sync_copies_approved_files_and_removes_ones_no_longer_approved(self):
        images = self.w.pack / "Images"
        images.mkdir()
        (images / "keep-artwork.svg").write_text("<svg/>")
        old = f"{SPECIES[1]}-inat-99.jpg"
        (images / old).write_bytes(b"old")
        name = f"{SPECIES[0]}-inat-11.jpg"
        removed = publish_global.sync_images(images, {name: self.w.thumbs / name})
        self.assertEqual(removed, [old])
        self.assertEqual(sorted(p.name for p in images.iterdir()), [name, "keep-artwork.svg"])


if __name__ == "__main__":
    unittest.main()
