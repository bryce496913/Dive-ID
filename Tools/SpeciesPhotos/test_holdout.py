"""Holdout mode: independence from the reference photos, the observer split, licence and
quality filters, uncovered species, no-match subjects, downloads and the freeze. No network."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import holdout
import inat
import licences
from test_species_photos import FakeClient, observation, photo

POLICY = licences.load_policy()
RAY, EEL = "00000000-0000-0000-0000-0000000000a1", "00000000-0000-0000-0000-0000000000b2"


def record(sid, name, reference=None, category="ray"):
    r = {"id": sid.upper(), "commonName": name, "scientificName": name, "categories": [category], "dataSources": []}
    if reference:
        oid, pid, creator = reference
        r["bundledImage"] = {"fileName": f"{sid}-inat-{pid}.jpg", "creatorName": creator,
                             "photoID": f"inaturalist:photo:{pid}", "observationID": f"inaturalist:observation:{oid}"}
    return r


def users_by_split():
    """Observer IDs that hash to each split, for deterministic fixtures."""
    out = {"holdout": [], "development": []}
    for uid in range(2, 400):
        out[holdout.split_of(uid)].append(uid)
    return out


class Client(FakeClient):
    def taxon_by_name(self, name):
        self.calls.append(("taxon", name))
        return {"results": self.taxa_responses.get(name, [])}, "2026-10-29"


def client_for(listings, taxa=None):
    taxa = taxa or {name: [{"id": tid, "name": name, "rank": "species", "is_active": True}] for name, tid in (("Ray", 10), ("Eel", 20))}
    return Client(taxa=taxa, observations={(tid, tuple(POLICY["allowedLicences"])): {"results": obs} for tid, obs in listings.items()})


class HoldoutSelectionTests(unittest.TestCase):
    def setUp(self):
        self.users = users_by_split()

    def test_photos_come_from_other_observations_and_observers_than_the_reference(self):
        h, d = self.users["holdout"], self.users["development"]
        listing = [
            observation(500, [photo(5000)], user=1, name="Ref Person"),         # the reference observation
            observation(501, [photo(5010)], user=1, name="Ref Person"),         # same observer, another observation
            observation(502, [photo(5020)], user=h[0], name="refperson"),       # matches the reference creator name
            observation(503, [photo(5030)], user=h[1], name="A"),
            observation(504, [photo(5040), photo(5041)], user=h[2], name="B"),  # only its first photo
            observation(505, [photo(5050, licence="cc-by-nd")], user=h[3], name="C"),  # licence not allowed
            observation(506, [photo(5060, width=300, height=200)], user=h[4], name="D"),  # too small
            observation(507, [photo(5070)], user=h[5], name="E"),
            observation(508, [photo(5080)], user=h[6], name="F"),               # over the limit of 3
            observation(509, [photo(5090)], user=d[0], name="G"),
            observation(510, [photo(5100)], user=h[1], name="A"),               # A already used
        ]
        records = [record(RAY, "Ray", reference=(500, 5000, "refperson"))]
        picked, counts = holdout.select(client_for({10: listing}), records, POLICY)
        self.assertEqual([e["photoID"] for e in picked["holdout"]], ["inaturalist:photo:5030", "inaturalist:photo:5040", "inaturalist:photo:5070"])
        self.assertEqual([e["photoID"] for e in picked["development"]], ["inaturalist:photo:5090"])
        self.assertEqual(counts, {"species": 1, "notYetFetched": 0, "unresolved": 0})
        first = picked["holdout"][0]
        self.assertTrue(first["covered"])
        self.assertEqual((first["group"], first["expected"], first["underwater"]), ("ray", "species", None))
        self.assertEqual(first["observerID"], f"inaturalist:user:{h[1]}")
        self.assertTrue(first["photoURL"].endswith("/medium.jpg"))
        self.assertEqual(first["licenseName"], "CC BY-NC 4.0")

    def test_observers_never_appear_in_both_splits(self):
        for uid in range(2, 400):
            self.assertEqual(holdout.split_of(uid), holdout.split_of(uid))
        self.assertTrue(self.users["holdout"] and self.users["development"])
        with self.assertRaises(AssertionError):
            holdout.check_independent({"holdout": [{"observerID": "u1"}], "development": [{"observerID": "u1"}]}, {})

    def test_species_without_a_reference_photo_are_included_and_unfetched_ones_counted(self):
        listing = [observation(600, [photo(6000)], user=self.users["holdout"][0], name="A")]
        records = [record(EEL, "Eel", category="eel"), record(RAY, "Ray", reference=(1, 1, "x"))]
        client = client_for({20: listing})
        original = client.observations

        def observations(taxon_id, licence_codes, per_page=30):
            if taxon_id == 10:
                raise inat.Offline("not cached")
            return original(taxon_id, licence_codes, per_page)
        client.observations = observations
        picked, counts = holdout.select(client, records, POLICY)
        self.assertEqual([(e["speciesID"], e["covered"], e["group"]) for e in picked["holdout"]], [(EEL, False, "eel")])
        self.assertEqual(counts["notYetFetched"], 1)

    def test_photos_rejected_in_review_are_never_used(self):
        listing = [observation(700, [photo(7000)], user=self.users["holdout"][0], name="A")]
        picked, _ = holdout.select(client_for({10: listing}), [record(RAY, "Ray")], POLICY, excluded={7000})
        self.assertEqual(picked["holdout"], [])

    def test_no_match_subjects(self):
        taxa = {"Cichlidae": [{"id": 90, "name": "Cichlidae", "rank": "family", "is_active": True}]}
        listing = [observation(800 + i, [photo(8000 + i)], user=uid, name=f"N{i}") for i, uid in enumerate(range(2, 12))]
        picked = holdout.select_no_match(client_for({90: listing}, taxa=taxa), POLICY, taxa={"Cichlidae": "freshwater fish", "Missing": "x"})
        everything = picked["holdout"] + picked["development"]
        self.assertEqual(len(everything), holdout.NO_MATCH_PER_TAXON)
        self.assertTrue(all(e["expected"] == "noMatch" and e["speciesID"] is None and not e["covered"] for e in everything))
        self.assertTrue(all(e["split"] == holdout.split_of(int(e["observerID"].rpartition(":")[2])) for e in everything))


class DownloadAndFreezeTests(unittest.TestCase):
    def test_download_records_hashes_and_skips_cached_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            photos = [{"photoID": "inaturalist:photo:1", "photoURL": "u1", "licenceCode": "cc-by"}]
            fetched = []
            holdout.download(photos, tmp, POLICY, fetch=lambda url: fetched.append(url) or b"jpeg", sleep=lambda s: None)
            self.assertEqual(photos[0]["sha256"], hashlib.sha256(b"jpeg").hexdigest())
            holdout.download(photos, tmp, POLICY, fetch=lambda url: fetched.append(url) or b"jpeg", sleep=lambda s: None)
            self.assertEqual(fetched, ["u1"], "a cached file with a matching hash isn't fetched again")
            with self.assertRaises(ValueError):
                holdout.download([{"photoID": "inaturalist:photo:2", "photoURL": "u2", "licenceCode": "cc-by-nd"}], tmp, POLICY, fetch=lambda u: b"")

    def test_freeze_records_the_hash_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest, frozen = Path(tmp) / "Holdout.v1.json", Path(tmp) / "Freeze.json"
            manifest.write_text(json.dumps({"photos": [{"photoID": "p", "sha256": "x"}]}))
            record_ = holdout.freeze(manifest, frozen)
            self.assertEqual(record_["holdoutManifestSHA256"], hashlib.sha256(manifest.read_bytes()).hexdigest())
            self.assertEqual(holdout.freeze(manifest, frozen), record_, "re-freezing the same manifest is a no-op")
            manifest.write_text(json.dumps({"photos": [{"photoID": "q", "sha256": "y"}]}))
            with self.assertRaises(SystemExit):
                holdout.freeze(manifest, frozen)

    def test_freeze_needs_every_photo_downloaded(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "Holdout.v1.json"
            manifest.write_text(json.dumps({"photos": [{"photoID": "p"}]}))
            with self.assertRaises(SystemExit):
                holdout.freeze(manifest, Path(tmp) / "Freeze.json")


if __name__ == "__main__":
    unittest.main()
