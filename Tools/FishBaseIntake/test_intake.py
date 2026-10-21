"""Synthetic tests for the FishBase/SeaLifeBase intake. Rows are invented; no network."""
import hashlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch  # noqa: E402
import resolve  # noqa: E402


def species(server, code, name):
    genus, epithet = name.split(" ")
    return {"server": server, "SpecCode": code, "Genus": genus, "Species": epithet}


def synonym(server, code, name, status="synonym", level="Species"):
    genus, epithet = name.split(" ")
    return {"server": server, "SpecCode": code, "SynGenus": genus, "SynSpecies": epithet, "Status": status, "TaxonLevel": level}


INDEX = resolve.NameIndex(
    [species("fb", 1, "Dascyllus melanurus"), species("fb", 2, "Chrysiptera hemicyanea"),
     species("fb", 3, "Turrum fulvoguttatum"), species("fb", 4, "Chromis viridis"),
     species("fb", 5, "Chromis virides"), species("slb", 10, "Holothuria atra"),
     species("fb", 6, "Twin name"), species("slb", 11, "Twin name")],
    [synonym("fb", 3, "Carangoides fulvoguttatus"),
     synonym("fb", 1, "Old dascyllus"), synonym("fb", 2, "Old dascyllus"),
     synonym("fb", 4, "Unsure chromis", status="ambiguous synonym"),
     synonym("fb", 2, "Wrong name", status="misapplied name"),
     synonym("fb", 2, "Genus only", level="Genus")])


class ResolutionTests(unittest.TestCase):
    def test_exact_name_resolves(self):
        self.assertEqual(INDEX.resolve("Dascyllus  melanurus")[:2], ("exact", {("fb", 1)}))

    def test_unique_synonym_resolves_to_accepted_species(self):
        self.assertEqual(INDEX.resolve("Carangoides fulvoguttatus")[:2], ("synonym", {("fb", 3)}))

    def test_synonym_of_several_species_is_flagged_ambiguous(self):
        resolution, codes, _, note = INDEX.resolve("Old dascyllus")
        self.assertEqual((resolution, codes), ("ambiguous", {("fb", 1), ("fb", 2)}))
        self.assertIn("more than one species", note)

    def test_ambiguous_synonym_status_is_flagged(self):
        self.assertEqual(INDEX.resolve("Unsure chromis")[0], "ambiguous")

    def test_name_valid_in_both_databases_is_ambiguous(self):
        self.assertEqual(INDEX.resolve("Twin name")[0], "ambiguous")

    def test_misapplied_and_genus_level_synonyms_never_resolve(self):
        self.assertEqual(INDEX.resolve("Wrong name")[0], "unresolved")
        self.assertEqual(INDEX.resolve("Genus only")[0], "unresolved")

    def test_genus_misspelling_is_corrected(self):
        self.assertEqual(INDEX.resolve("Jascyllus melanurus")[:3], ("corrected", {("fb", 1)}, "dascyllus melanurus"))
        self.assertEqual(INDEX.resolve("Shrysiptera hemicyanea")[:3], ("corrected", {("fb", 2)}, "chrysiptera hemicyanea"))

    def test_misspelled_synonym_is_corrected_to_its_accepted_species(self):
        resolution, codes, corrected, _ = INDEX.resolve("Carangoidcs fulvoguttatus")
        self.assertEqual((resolution, codes, corrected), ("corrected", {("fb", 3)}, "carangoides fulvoguttatus"))
        self.assertEqual(INDEX.resolve("Old dascylus")[0], "unresolved", "ambiguous synonyms are never correction targets")

    def test_epithet_misspelling_within_one_edit_is_corrected(self):
        self.assertEqual(INDEX.resolve("Holothuria atrra")[:2], ("corrected", {("slb", 10)}))

    def test_epithet_two_edits_away_is_not_corrected(self):
        self.assertEqual(INDEX.resolve("Holothuria atrrra")[0], "unresolved")

    def test_tied_spelling_corrections_are_not_guessed(self):
        resolution, codes, corrected, note = INDEX.resolve("Chromis viridas")
        self.assertEqual((resolution, codes, corrected), ("unresolved", set(), None))
        self.assertIn("chromis virides", note)
        self.assertIn("chromis viridis", note)

    def test_non_binomial_is_unresolved(self):
        self.assertEqual(INDEX.resolve("Opistognathus sp.")[0], "unresolved")


class DeduplicationTests(unittest.TestCase):
    def test_existing_record_keeps_identity_and_candidates_become_duplicates(self):
        inputs = [
            {"inputKind": "existing", "inputID": "uuid-1", "pack": "TropicalPacific", "inputName": "Jascyllus melanurus"},
            {"inputKind": "candidate", "inputID": "C-1", "pack": "", "inputName": "Dascyllus melanurus"},
            {"inputKind": "candidate", "inputID": "C-2", "pack": "", "inputName": "Carangoides fulvoguttatus"},
            {"inputKind": "candidate", "inputID": "C-3", "pack": "", "inputName": "Old dascyllus"},
        ]
        rows = {r["inputID"]: r for r in resolve.resolve_all(INDEX, inputs)}
        self.assertEqual(rows["uuid-1"]["duplicateOf"], "")
        self.assertEqual(rows["uuid-1"]["correctedFrom"], "Jascyllus melanurus")
        self.assertEqual(rows["uuid-1"]["acceptedName"], "Dascyllus melanurus")
        self.assertEqual(rows["C-1"]["duplicateOf"], "uuid-1")
        self.assertEqual(rows["C-2"]["acceptedName"], "Turrum fulvoguttatum")
        self.assertEqual((rows["C-3"]["flagged"], rows["C-3"]["specCode"]), ("yes", ""))
        summary = resolve.summarize(list(rows.values()), {"servers": {"fb": {"release": "v26.06"}}, "license": "CC BY-NC 4.0"})
        self.assertEqual((summary["duplicates"], summary["flagged"], summary["uniqueResolvedSpecies"]), (1, 1, 2))


class FetchPinTests(unittest.TestCase):
    def setUp(self):
        self.payload = b"parquet bytes"
        self.manifest = {"source": "https://example.test", "servers": {"fb": {"release": "v0", "tables": {
            "species": {"key": "fb/species.parquet", "etag": hashlib.md5(self.payload).hexdigest(), "size": len(self.payload)}}}}}

    def opener(self, body):
        return lambda url, timeout: io.BytesIO(body)

    def test_matching_download_is_cached_and_reused_offline(self):
        with tempfile.TemporaryDirectory() as cache:
            path = fetch.fetch(self.manifest, cache, "fb", "species", opener=self.opener(self.payload))
            self.assertEqual(path.read_bytes(), self.payload)
            self.assertEqual(fetch.fetch(self.manifest, cache, "fb", "species", offline=True), path)

    def test_changed_download_fails_closed_and_leaves_no_file(self):
        with tempfile.TemporaryDirectory() as cache:
            with self.assertRaises(fetch.PinMismatch):
                fetch.fetch(self.manifest, cache, "fb", "species", opener=self.opener(b"parquet bytez"))
            self.assertEqual(list(Path(cache).rglob("*")), [Path(cache) / "fb"])

    def test_tampered_cache_is_rejected(self):
        with tempfile.TemporaryDirectory() as cache:
            path = fetch.cached_path(cache, "fb", "species")
            path.parent.mkdir(parents=True)
            path.write_bytes(b"something else")
            with self.assertRaises(fetch.PinMismatch):
                fetch.fetch(self.manifest, cache, "fb", "species", offline=True)

    def test_offline_without_cache_never_downloads(self):
        with tempfile.TemporaryDirectory() as cache:
            with self.assertRaises(FileNotFoundError):
                fetch.fetch(self.manifest, cache, "fb", "species", offline=True, opener=lambda *a, **k: self.fail("downloaded"))


if __name__ == "__main__":
    unittest.main()
