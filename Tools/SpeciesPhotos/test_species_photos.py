"""Species photo intake: licence policy, taxon matching, selection, attribution and determinism.
No network: iNaturalist responses are canned; FishBase picture rows are passed directly."""
import json
import random
import tempfile
import unittest
from pathlib import Path

import inat
import licences
import size_projection
import species_photos as sp
import thumbnails

POLICY = licences.load_policy()


def photo(pid, licence="cc-by-nc", width=2000, height=1400, **extra):
    return {"id": pid, "license_code": licence, "original_dimensions": {"width": width, "height": height},
            "url": f"https://inaturalist-open-data.s3.amazonaws.com/photos/{pid}/square.jpg",
            "attribution": "(c) Jane Diver, some rights reserved (CC BY-NC)", "flags": [], "hidden": False, **extra}


def observation(oid, photos, user=1, name="Jane Diver", **extra):
    return {"id": oid, "quality_grade": "research", "captive": False, "observed_on": "2024-05-01",
            "user": {"id": user, "login": f"user{user}", "name": name}, "photos": photos, **extra}


class FakeClient:
    """Canned taxa and observation responses keyed by name / taxon and licence set."""
    def __init__(self, taxa=None, observations=None):
        self.taxa_responses, self.observation_responses, self.calls = taxa or {}, observations or {}, []

    def taxa(self, name):
        self.calls.append(("taxa", name))
        return {"results": self.taxa_responses.get(name, [])}, "2026-10-27"

    def observations(self, taxon_id, licence_codes, per_page=30):
        self.calls.append(("observations", taxon_id, tuple(licence_codes)))
        return self.observation_responses.get((taxon_id, tuple(licence_codes)), {"results": [], "total_results": 0}), "2026-10-27"


class LicencePolicyTests(unittest.TestCase):
    def test_each_licence_in_or_out(self):
        expected = {
            "cc0": licences.ALLOWED, "cc-by": licences.ALLOWED, "cc-by-nc": licences.ALLOWED,
            "cc-by-sa": licences.LATER_DECISION, "cc-by-nc-sa": licences.LATER_DECISION,
            "cc-by-nd": licences.EXCLUDED_NO_DERIVATIVES, "cc-by-nc-nd": licences.EXCLUDED_NO_DERIVATIVES,
            None: licences.EXCLUDED_UNKNOWN, "": licences.EXCLUDED_UNKNOWN, "all-rights-reserved": licences.EXCLUDED_UNKNOWN,
            "gpl": licences.EXCLUDED_UNKNOWN,
        }
        for code, outcome in expected.items():
            self.assertEqual(licences.classify(code, POLICY), outcome, code)
        self.assertEqual(licences.classify("CC-BY-NC", POLICY), licences.ALLOWED, "case and spelling are normalised")

    def test_policy_is_configurable_but_never_allows_no_derivatives(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "policy.json"
            narrow = {**POLICY, "allowedLicences": ["cc0"]}
            path.write_text(json.dumps(narrow))
            policy = licences.load_policy(path)
            self.assertEqual(licences.classify("cc-by", policy), licences.EXCLUDED_UNKNOWN)
            path.write_text(json.dumps({**POLICY, "allowedLicences": ["cc-by-nd"]}))
            with self.assertRaises(ValueError):
                licences.load_policy(path)
            path.write_text(json.dumps({**POLICY, "laterDecisionLicences": ["cc-by"]}))
            with self.assertRaises(ValueError):
                licences.load_policy(path)


class TaxonMatchTests(unittest.TestCase):
    def test_exact_synonym_ambiguous_and_unmatched(self):
        exact = [{"id": 1, "name": "Pterois volitans", "rank": "species", "is_active": True}]
        self.assertEqual(sp.match_taxon("Pterois volitans", exact)["status"], sp.RESOLVED)
        synonym = [{"id": 2, "name": "Aetobatus narinari", "rank": "species", "matched_term": "Aetobatis narinari"}]
        self.assertEqual(sp.match_taxon("Aetobatis narinari", synonym), {"status": sp.SYNONYM, "candidates": [2], "taxonName": "Aetobatus narinari"})
        twice = [{"id": 3, "name": "Chromis x", "rank": "species"}, {"id": 4, "name": "Chromis x", "rank": "species"}]
        self.assertEqual(sp.match_taxon("Chromis x", twice)["status"], sp.AMBIGUOUS)
        self.assertEqual(sp.match_taxon("Nomen nudum", [])["status"], sp.UNMATCHED)
        genus = [{"id": 5, "name": "Pterois", "rank": "genus"}]
        self.assertEqual(sp.match_taxon("Pterois", genus)["status"], sp.UNMATCHED, "only species-rank taxa count")


class SelectionTests(unittest.TestCase):
    def test_only_wild_research_grade_allowed_large_unflagged_photos_with_a_creator(self):
        observations = [
            observation(1, [photo(10, licence="cc-by-nd")]),
            observation(2, [photo(20, licence=None)]),
            observation(3, [photo(30, licence="cc-by-sa")]),
            observation(4, [photo(40)], captive=True),
            observation(5, [photo(50)], quality_grade="needs_id"),
            observation(6, [photo(60, width=500, height=400)]),
            observation(7, [photo(70, hidden=True), photo(71, flags=[{"flag": "copyright"}])]),
            observation(8, [photo(80, attribution="")], name="", user=8),
            observation(9, [photo(90, licence="cc0")]),
        ]
        observations[7]["user"]["login"] = ""
        chosen = [p["id"] for _, p, *_ in sp.candidates(observations, POLICY)]
        self.assertEqual(chosen, [90])

    def test_landscape_first_one_per_observer_at_most_two(self):
        client = FakeClient(
            taxa={"Pterois volitans": [{"id": 7, "name": "Pterois volitans", "rank": "species"}]},
            observations={(7, ("cc0", "cc-by", "cc-by-nc")): {"results": [
                observation(1, [photo(11, width=1000, height=1500)], user=1),
                observation(2, [photo(21), photo(22)], user=1),
                observation(3, [photo(31)], user=2, name="Ann Reef"),
                observation(4, [photo(41)], user=3, name="Bo Sea"),
            ]}})
        rows = [{"speciesID": "a", "commonName": "Red Lionfish", "scientificName": "Pterois volitans", "sourceCode": None}]
        selected = sp.select(client, sp.resolve(client, rows), POLICY)
        photos = selected[0]["photos"]
        self.assertEqual([p["photoID"] for p in photos], ["inaturalist:photo:21", "inaturalist:photo:31"])
        self.assertEqual(photos[0]["photoURL"], "https://inaturalist-open-data.s3.amazonaws.com/photos/21/large.jpg")

    def test_a_chosen_photo_comes_first_and_an_excluded_one_never_returns(self):
        client = FakeClient(
            taxa={"Pterois volitans": [{"id": 7, "name": "Pterois volitans", "rank": "species"}]},
            observations={(7, ("cc0", "cc-by", "cc-by-nc")): {"results": [
                observation(1, [photo(11)], user=1),
                observation(2, [photo(21)], user=2, name="Ann Reef"),
                observation(3, [photo(31)], user=3, name="Bo Sea"),
                observation(4, [photo(41, licence="cc-by-nd")], user=4, name="Cy Deep"),
            ]}})
        rows = [{"speciesID": "A", "commonName": "Red Lionfish", "scientificName": "Pterois volitans", "sourceCode": None}]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "PhotoChoices.json"
            path.write_text(json.dumps({"chosen": [{"speciesID": "a", "photoID": "inaturalist:photo:31"},
                                                   {"speciesID": "a", "photoID": "inaturalist:photo:41"}],
                                        "excluded": [{"speciesID": "a", "photoID": "inaturalist:photo:11"}]}))
            selected = sp.select(client, sp.resolve(client, rows), POLICY, sp.load_choices(path))
            self.assertEqual(sp.load_choices(Path(tmp) / "missing.json"), ({}, set()))
        self.assertEqual([p["photoID"] for p in selected[0]["photos"]], ["inaturalist:photo:31", "inaturalist:photo:21"],
                         "chosen first; the excluded photo is gone; a chosen ND photo still fails the licence filter")

    def test_cached_only_skips_species_not_yet_fetched(self):
        class PartlyCached(FakeClient):
            def observations(self, taxon_id, licence_codes, per_page=30):
                if taxon_id == 8:
                    raise inat.Offline("not cached")
                return super().observations(taxon_id, licence_codes, per_page)
        client = PartlyCached(
            taxa={"Pterois volitans": [{"id": 7, "name": "Pterois volitans", "rank": "species"}],
                  "Aetobatus narinari": [{"id": 8, "name": "Aetobatus narinari", "rank": "species"}]},
            observations={(7, ("cc0", "cc-by", "cc-by-nc")): {"results": [observation(1, [photo(11)])]}})
        rows = [{"speciesID": "a", "commonName": "Red Lionfish", "scientificName": "Pterois volitans", "sourceCode": None},
                {"speciesID": "b", "commonName": "Spotted Eagle Ray", "scientificName": "Aetobatus narinari", "sourceCode": None}]
        selected, pending = sp.select_cached(client, rows, POLICY)
        self.assertEqual(([r["speciesID"] for r in selected], pending), (["a"], 1))
        self.assertEqual(sp.coverage(selected, [], pending)["notYetFetched"], 1)

    def test_a_flagged_taxon_is_never_searched_for_photos(self):
        client = FakeClient(taxa={"Aetobatis narinari": [{"id": 2, "name": "Aetobatus narinari", "rank": "species",
                                                          "matched_term": "Aetobatis narinari"}]})
        rows = [{"speciesID": "a", "commonName": "Ray", "scientificName": "Aetobatis narinari", "sourceCode": None}]
        selected = sp.select(client, sp.resolve(client, rows), POLICY)
        self.assertEqual(selected[0]["photos"], [])
        self.assertFalse(any(call[0] == "observations" for call in client.calls))

    def test_a_species_with_only_share_alike_photos_is_recorded_for_later(self):
        client = FakeClient(
            taxa={"Chromis z": [{"id": 9, "name": "Chromis z", "rank": "species"}]},
            observations={(9, ("cc-by-sa", "cc-by-nc-sa")): {"results": [], "total_results": 3}})
        rows = [{"speciesID": "a", "commonName": "Chromis", "scientificName": "Chromis z", "sourceCode": None}]
        selected = sp.select(client, sp.resolve(client, rows), POLICY)
        self.assertEqual(selected[0]["laterDecisionPhotoObservations"], 3)
        self.assertEqual(sp.coverage(selected, [])["laterDecisionOnly"], 1)


def selected_fixture():
    client = FakeClient(
        taxa={f"Genus s{i}": [{"id": i, "name": f"Genus s{i}", "rank": "species"}] for i in range(1, 6)},
        observations={(i, ("cc0", "cc-by", "cc-by-nc")): {"results": [
            observation(100 * i + 1, [photo(1000 * i + 1, licence="cc-by")], user=i),
            observation(100 * i + 2, [photo(1000 * i + 2)], user=i + 50, name=f"Diver {i}"),
        ]} for i in range(1, 5)})
    rows = [{"speciesID": f"0000000{i}", "commonName": f"Fish {i}", "scientificName": f"Genus s{i}", "sourceCode": None}
            for i in range(1, 6)]
    return sp.select(client, sp.resolve(client, rows), POLICY)


class ManifestTests(unittest.TestCase):
    def test_every_photo_has_complete_attribution(self):
        required = ["creatorName", "licenseName", "licenseURL", "sourceName", "sourcePageURL", "photoURL",
                    "photoID", "observationID", "retrievedOn", "taxonID"]
        photos = sp.manifest(selected_fixture(), POLICY)["photos"]
        self.assertEqual(len(photos), 8)
        for entry in photos:
            for field in required:
                self.assertTrue(isinstance(entry.get(field), str) and entry[field].strip(), (field, entry))
            self.assertTrue(entry["licenseURL"].startswith("https://creativecommons.org/"))
            self.assertIn(entry["licenceCode"], POLICY["allowedLicences"])
            self.assertEqual(entry["review"], {"status": "pending"})

    def test_manifest_is_deterministic(self):
        selected = selected_fixture()
        first = json.dumps(sp.manifest(selected, POLICY), sort_keys=True)
        shuffled = list(selected)
        random.Random(4).shuffle(shuffled)
        self.assertEqual(json.dumps(sp.manifest(shuffled, POLICY), sort_keys=True), first)
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / "a.json", Path(tmp) / "b.json"
            sp.write_json(a, sp.manifest(selected, POLICY))
            sp.write_json(b, sp.manifest(shuffled, POLICY))
            self.assertEqual(a.read_bytes(), b.read_bytes())

    def test_coverage_counts(self):
        report = sp.coverage(selected_fixture(), [])
        self.assertEqual((report["species"], report["withINaturalistPhoto"], report["noPhoto"], report["photosSelected"]), (5, 4, 1, 8))


class FishBaseFallbackTests(unittest.TestCase):
    def picture(self, code, name, copyright=None, public=False, kind="underwater photo", preferred=True, ctr=1):
        genus, species = name.split()
        return {"database": "FishBase", "SpecCode": code, "PicGenus": genus, "PicSpecies": species, "PicName": f"{genus[:2]}{species[:3]}_u0.jpg",
                "PictureType": kind, "AuthName": "Randall, J.E.", "Copyright": copyright, "PublicDomain": public,
                "PicPreferred": preferred, "BestPic": False, "autoctr": ctr}

    def test_no_fishbase_photo_is_taken_without_an_allowed_licence(self):
        rows = [{"speciesID": "a", "scientificName": "Genus one", "commonName": "One", "sourceCode": "FishBase:SpecCode:1"},
                {"speciesID": "b", "scientificName": "Genus two", "commonName": "Two", "sourceCode": None},
                {"speciesID": "c", "scientificName": "Genus three", "commonName": "Three", "sourceCode": "FishBase:SpecCode:3"},
                {"speciesID": "d", "scientificName": "Genus four", "commonName": "Four", "sourceCode": "FishBase:SpecCode:4"}]
        pictures = [self.picture(1, "Genus one", "non-commercial use"), self.picture(2, "Genus two", "free use"),
                    self.picture(3, "Genus three", public=True), self.picture(4, "Genus four", kind="b/w drawing")]
        out = {r["speciesID"]: r for r in sp.fishbase_fallback(rows, pictures)}
        self.assertEqual(out["a"]["action"], "permission needed", "'non-commercial use' is not a licence")
        self.assertEqual(out["b"]["action"], "permission needed", "matched by scientific name when no code")
        self.assertEqual(out["c"]["action"], "confirm public domain")
        self.assertNotIn("d", out, "drawings are not offered")
        self.assertEqual(out["a"]["photoPageURL"], "https://www.fishbase.se/photos/PicturesSummary.php?ID=1&what=species")
        csv_text = sp.permission_csv(list(out.values()))
        self.assertTrue(csv_text.startswith("scientificName,commonName,database,photographer,photoPageURL"))
        report = sp.coverage([{**r, "status": sp.RESOLVED, "photos": []} for r in rows], list(out.values()))
        self.assertEqual((report["withFishBasePhoto"], report["permissionNeeded"], report["confirmPublicDomain"], report["noPhoto"]), (0, 2, 1, 1))


class ClientTests(unittest.TestCase):
    def test_cached_offline_and_throttled(self):
        with tempfile.TemporaryDirectory() as tmp:
            now = [0.0]; slept = []; urls = []
            def opener(url):
                urls.append(url); return {"results": [{"id": 1, "name": "Genus one", "rank": "species", "ancestors": ["large"]}]}
            client = inat.Client(tmp, opener=opener, clock=lambda: now[0], sleep=lambda s: (slept.append(s), now.__setitem__(0, now[0] + s)))
            client.taxa("Genus one"); client.taxa("Genus two")
            self.assertEqual(len(urls), 2)
            self.assertEqual(slept, [1.0], "at most one request per second")
            client.taxa("Genus one")
            self.assertEqual(len(urls), 2, "a cached response is not requested again")
            offline = inat.Client(tmp, offline=True)
            self.assertEqual(offline.taxa("Genus one")[0], {"total_results": None, "results": [{"id": 1, "name": "Genus one", "rank": "species"}]},
                             "cached responses keep only the fields the pipeline reads")
            with self.assertRaises(inat.Offline):
                offline.taxa("Genus three")
        self.assertIn("DiveID-SpeciesPhotos", inat.USER_AGENT)

    def test_a_dropped_connection_is_retried(self):
        import http.client, io
        from unittest import mock
        calls = []
        def urlopen(request, timeout):
            calls.append(request.get_header("User-agent"))
            if len(calls) == 1:
                raise http.client.RemoteDisconnected("closed")
            return io.BytesIO(b'{"results": []}')
        with mock.patch("urllib.request.urlopen", urlopen), mock.patch("time.sleep"):
            self.assertEqual(inat.Client._open("https://api.inaturalist.org/v1/taxa"), {"results": []})
        self.assertEqual(calls, [inat.USER_AGENT] * 2)


class ThumbnailTests(unittest.TestCase):
    def test_a_failed_download_is_skipped_and_recorded(self):
        def fetch(url):
            if "/2/" in url:
                raise OSError("404")
            return b"jpeg"
        photos = [{"photoID": f"inaturalist:photo:{n}", "speciesID": "S", "licenceCode": "cc-by",
                   "photoURL": f"https://inaturalist-open-data.s3.amazonaws.com/photos/{n}/large.jpg"} for n in (1, 2, 3)]
        failures = []
        with tempfile.TemporaryDirectory() as tmp:
            index = thumbnails.make(photos, tmp, POLICY, fetch=fetch, sleep=lambda s: None,
                                    resize=lambda d, n: (d, (400, 300)), failures=failures, save_every=1)
            saved = json.loads((Path(tmp) / thumbnails.INDEX).read_text())
        self.assertEqual(sorted(index), ["inaturalist:photo:1", "inaturalist:photo:3"])
        self.assertEqual(saved, index)
        self.assertEqual([f["photoID"] for f in failures], ["inaturalist:photo:2"])

    def test_only_allowed_photos_are_downloaded_once_and_indexed(self):
        with tempfile.TemporaryDirectory() as tmp:
            fetched = []
            def fetch(url):
                fetched.append(url); return b"original bytes"
            resize = lambda data, side: (b"thumb:" + data, (side, side * 3 // 4))
            manifest_photos = sp.manifest(selected_fixture(), POLICY)["photos"][:2]
            index = thumbnails.make(manifest_photos, tmp, POLICY, fetch=fetch, sleep=lambda s: None, resize=resize)
            self.assertEqual(len(fetched), 2)
            entry = index[manifest_photos[0]["photoID"]]
            self.assertEqual(entry["fileName"], "00000001-inat-1001.jpg")
            self.assertEqual((entry["width"], entry["bytes"]), (400, len(b"thumb:original bytes")))
            thumbnails.make(manifest_photos, tmp, POLICY, fetch=fetch, sleep=lambda s: None, resize=resize)
            self.assertEqual(len(fetched), 2, "an indexed, unchanged thumbnail is not fetched again")
            with self.assertRaises(ValueError):
                thumbnails.make([dict(manifest_photos[0], licenceCode="cc-by-sa")], tmp, POLICY, fetch=fetch, resize=resize)

    def test_size_projection_scales_the_sample(self):
        sample = [{"thumbnail": 40_000, "large": 200_000, "original": 900_000}, {"thumbnail": 60_000, "large": 300_000, "original": 1_100_000}]
        out = size_projection.project(sample, 4000)
        self.assertEqual(out["thumbnail"], {"averageBytes": 50_000, "onePerSpeciesMB": 200.0, "twoPerSpeciesMB": 400.0})
        self.assertEqual(out["original"]["onePerSpeciesMB"], 4000.0)


if __name__ == "__main__":
    unittest.main()
