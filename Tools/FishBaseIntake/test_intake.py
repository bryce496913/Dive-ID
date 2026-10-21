"""Synthetic tests for the FishBase/SeaLifeBase intake. Rows are invented; no network."""
import hashlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build  # noqa: E402
import distribution  # noqa: E402
import fetch  # noqa: E402
import merge_plan  # noqa: E402
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


class BuildMappingTests(unittest.TestCase):
    def test_clean_removes_reference_markers_and_html(self):
        self.assertEqual(build.clean("Found on <i>Acropora</i> reefs (Ref. 1602, 9710) .  Feeds at night (Ref. 4)."),
                         "Found on Acropora reefs. Feeds at night.")
        self.assertEqual(build.clean("Juveniles <6 cm SL are <i>blue</i>; adults > 10 cm.<br/>"), "Juveniles <6 cm SL are blue; adults > 10 cm.")
        self.assertEqual(build.clean("Reports by Heemstra & Randall (1984, Ref. 3153) from Oman; Africa (including Mauritius, Ref. 37792) "
                                     "to Hawaii, as reported by Ref. 9710, 1602."),
                         "Reports by Heemstra & Randall (1984) from Oman; Africa (including Mauritius) to Hawaii, as reported.")

    def test_colours_and_markings_come_from_whole_words(self):
        text = "Body bluish with three dark bars and a black ocellus; fins yellowish. Barbels absent? Scarlet-edged."
        self.assertEqual(build.terms_in(text, build.COLOR_TERMS), ["black", "blue", "red", "yellow"])
        self.assertEqual(build.terms_in(text, build.MARKING_TERMS), ["spots", "stripes"], "'barbels absent' must not add barbels")
        self.assertEqual(build.terms_in("barracuda-like body", build.COLOR_TERMS), [])

    def test_category_prefers_queue_then_family_then_class(self):
        self.assertEqual(build.category_for("shark", "Holothuriidae", "Holothuroidea"), ["shark"])
        self.assertEqual(build.category_for("needs_taxon_group", "Holothuriidae", None), ["sea cucumber"])
        self.assertEqual(build.category_for(None, "Parechinidae", "Echinoidea"), ["sea urchin"])
        self.assertEqual(build.category_for(None, "Gobiidae", "Teleostei"), ["fish"])
        self.assertEqual(build.category_for(None, "Unknownidae", None), [])

    def test_regions_from_fao_areas_and_countries(self):
        self.assertEqual(build.regions_for([31], ["Bahamas"]), ["atlantic", "bahamas", "caribbean", "western atlantic"])
        self.assertEqual(build.regions_for([71], ["Fiji", "Nowhere"]), ["fiji", "indo-pacific", "pacific"])
        self.assertEqual(build.regions_for([37], ["Curacao"]), ["caribbean", "curacao", "curaçao"])

    def test_fin_clues_render_ranges(self):
        m = {"DorsalSpinesMin": 12, "DorsalSpinesMax": 12, "DorsalSoftRaysMin": 12, "DorsalSoftRaysMax": 13, "AnalFinSpinesMin": 2, "Araymin": 0}
        self.assertEqual(build.fin_clues(m), ["Dorsal fin: 12 spines, 12–13 soft rays", "Anal fin: 2 spines"])

    def test_freshwater_only_species_are_out_of_scope(self):
        self.assertTrue(build.lives_in_sea({"Saltwater": -1, "Brack": 0}))
        self.assertTrue(build.lives_in_sea({"Saltwater": 0, "Brack": 1}))
        self.assertFalse(build.lives_in_sea({"Saltwater": 0, "Brack": 0}))

    def source(self, **species):
        sp = {"FBname": "Blacktail humbug", "LTypeMaxM": "SL", "DepthRangeShallow": 1, "DepthRangeDeep": 68,
              "DemersPelag": "reef-associated", "BodyShapeI": "short and / or deep", "Dangerous": "venomous", "Author": "Bleeker, 1854",
              "Comments": "Traditionally harvested for the aquarium trade (Ref. 1). Minimum depth from Ref. 128982. Adults inhabit sheltered lagoons (Ref. 9). Holotype lost. Feeds on plankton (Ref. 4, 5).", "Length": 54.79999923706055}
        sp.update(species)
        return {"release": "v26.06", "species": sp, "family": {"Family": "Pomacentridae", "Order": "Ovalentaria", "Class": "Teleostei"},
                "english_names": ["Blacktail humbug", "Black-tailed dascyllus", "Damsel"], "ecology": [{"Epipelagic": -1, "Oceanic": -1, "CoralReefs": -1, "Schooling": -1}],
                "morphdat": {"AddChars": "White with 3 black bars (Ref. 2).", "CShape": "more or less truncate", "PosofMouth": "terminal", "BarbelsNo": 0},
                "range_text": "Western Pacific (Ref. 3).", "fao_codes": [71], "fao_names": ["Pacific, Western Central"], "countries": ["Fiji"], "main_ref": "Allen 1991"}

    def entry(self):
        return {"id": "id-1", "server": "fb", "specCode": "5111", "acceptedName": "Dascyllus melanurus", "inputName": "Jascyllus melanurus",
                "resolution": "corrected", "categories": ["fish"]}

    def test_build_profile_maps_source_fields(self):
        p = build.build_profile(self.entry(), self.source())
        self.assertEqual((p["commonName"], p["aliases"]), ("Blacktail humbug", ["Black-tailed dascyllus", "Damsel"]))
        self.assertEqual((p["colors"], p["markings"], p["bodyShapes"]), (["black", "white"], ["stripes"], ["compressed"]))
        self.assertEqual(p["habitats"], ["reef", "shallow"], "only pelagic species get open water")
        self.assertEqual((p["behaviors"], p["regions"]), (["schooling"], ["fiji", "indo-pacific", "pacific"]))
        self.assertEqual(p["measurements"], {"typicalObservedMinimumCentimeters": None, "typicalObservedMaximumCentimeters": None,
                                             "maximumRecordedCentimeters": 54.8, "type": "standardLength"})
        self.assertEqual((p["minimumDepthMeters"], p["maximumDepthMeters"], p["minimumSizeCentimeters"]), (1.0, 68.0, None))
        self.assertEqual(p["summary"], "Adults inhabit sheltered lagoons. Feeds on plankton.", "fisheries, reference and specimen sentences are dropped")
        self.assertEqual(p["typicalHabitat"], "Adults inhabit sheltered lagoons.")
        self.assertEqual((p["geographicRange"], p["cautions"]), ("Western Pacific.", ["Venomous: avoid touching."]))
        self.assertEqual((p["tailShape"], p["mouthAndHeadShape"]), ("truncate", ["terminal mouth"]))
        self.assertEqual(p["taxonomy"]["sourceScientificName"], "Jascyllus melanurus")
        self.assertEqual(p["dataSources"][0]["stableSourceID"], "FishBase:SpecCode:5111")
        self.assertEqual(p["dataSources"][0]["sourceLicense"], "CC BY-NC 4.0")
        self.assertEqual((p["review"]["status"], p["bundledImage"]), ("draft", None))

    def test_missing_source_text_uses_honest_fallbacks(self):
        src = self.source(Comments=None, FBname=None, Length=None)
        src.update(english_names=[], morphdat=None, range_text="", fao_names=[], countries=[])
        p = build.build_profile(self.entry(), src)
        self.assertEqual(p["commonName"], "Dascyllus melanurus")
        self.assertEqual(p["summary"], "Pomacentridae species; reef-associated.")
        self.assertTrue(p["distinguishingFeatures"])
        self.assertEqual(p["geographicRange"], "No range recorded in FishBase.")
        self.assertEqual((p["measurements"], p["maximumSizeCentimeters"]), (None, None))

    def test_unique_names_and_alias_collisions(self):
        a = {"id": "a", "commonName": "Spotted Grouper", "scientificName": "Aus one", "aliases": ["Reef cod"]}
        b = {"id": "b", "commonName": "spotted grouper", "scientificName": "Bus two", "aliases": ["Aus one", "Blue fish"]}
        c = {"id": "c", "commonName": "Queen Angelfish", "scientificName": "Cus three", "aliases": []}
        renamed = build.enforce_unique_names([a, b, c], {"queen angelfish", "holacanthus ciliaris"})
        self.assertEqual(renamed, ["a", "b", "c"])
        self.assertEqual((a["commonName"], b["commonName"], c["commonName"]),
                         ("Spotted Grouper (Aus one)", "spotted grouper (Bus two)", "Queen Angelfish (Cus three)"))
        self.assertEqual(b["aliases"], ["Blue fish"], "an alias may not be another species' name")

    def test_selection_builds_the_merge_plans_kept_uuids_only(self):
        resolution = [{"inputKind": "existing", "inputID": "tp-1", "resolution": "corrected", "inputName": "Jascyllus x"},
                      {"inputKind": "existing", "inputID": "car-1", "resolution": "exact", "inputName": "Aus bus"},
                      {"inputKind": "candidate", "inputID": "MARINE5K-00001", "resolution": "exact", "inputName": "Cus dus"},
                      {"inputKind": "candidate", "inputID": "MARINE5K-00002", "resolution": "exact", "inputName": "Dascyllus x"}]
        plan = [{"inputKind": "existing", "inputID": "tp-1", "pack": "TropicalPacific", "role": "keep", "plannedUUID": "tp-1"},
                {"inputKind": "existing", "inputID": "car-1", "pack": "Caribbean", "role": "keep", "plannedUUID": "car-1"},
                {"inputKind": "candidate", "inputID": "MARINE5K-00001", "pack": "", "role": "keep", "plannedUUID": "workbook-uuid"},
                {"inputKind": "candidate", "inputID": "MARINE5K-00002", "pack": "", "role": "retire", "plannedUUID": "tp-1"},
                {"inputKind": "candidate", "inputID": "MARINE5K-00003", "pack": "", "role": "unresolved", "plannedUUID": ""}]
        entries = build.select_entries(plan, resolution, [{"candidateID": "MARINE5K-00001", "proposedAppCategory": "shark"}], {"tp-1": ["fish"]})
        self.assertEqual([(e["inputID"], e["id"]) for e in entries], [("tp-1", "tp-1"), ("MARINE5K-00001", "workbook-uuid")])
        self.assertEqual((entries[0]["categories"], entries[1]["categories"], entries[1]["candidateCategory"]), (["fish"], None, "shark"))


class DistributionTests(unittest.TestCase):
    def test_basins_come_only_from_trusted_fao_records(self):
        entry = distribution.distribution_for(
            [{"AreaCode": 31, "Status": "native"}, {"AreaCode": 71, "Status": "questionable"}, {"AreaCode": 37, "Status": "introduced"}],
            [{"C_Code": "044", "Status": "native"}, {"C_Code": "242", "Status": "misidentification"}])
        self.assertEqual(entry["oceanBasins"], ["Atlantic", "Mediterranean and Black Sea"])
        self.assertEqual([(a["code"], a["counts"]) for a in entry["faoAreas"]], [(31, True), (37, True), (71, False)])
        self.assertEqual([(c["code"], c["counts"]) for c in entry["countries"]], [("044", True), ("242", False)])
        self.assertTrue(entry["distributionKnown"])

    def test_no_trusted_record_means_unknown_distribution(self):
        entry = distribution.distribution_for([{"AreaCode": 71, "Status": "error"}], [])
        self.assertEqual((entry["oceanBasins"], entry["distributionKnown"]), ([], False))

    def test_snapshot_round_trips_and_fails_closed(self):
        source = {"fb/v26.06/faoareas": "etag-1"}
        payload = {"species": {"fb:1": {"oceanBasins": ["Atlantic"]}}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Distribution.json"
            distribution.write_snapshot(path, source, payload)
            self.assertEqual(distribution.read_snapshot(path, source), payload)
            with self.assertRaises(distribution.IntegrityError, msg="a different pinned source"):
                distribution.read_snapshot(path, {"fb/v26.06/faoareas": "etag-2"})
            path.write_text(path.read_text().replace("Atlantic", "Pacific"))
            with self.assertRaises(distribution.IntegrityError, msg="an edited payload"):
                distribution.read_snapshot(path, source)

    def test_source_names_every_pinned_table_and_etag(self):
        manifest = {"servers": {"fb": {"release": "v1", "tables": {t: {"etag": f"e-{t}"} for t in distribution.TABLES}}}}
        self.assertEqual(distribution.source_of(manifest), {f"fb/v1/{t}": f"e-{t}" for t in distribution.TABLES})


class MergePlanTests(unittest.TestCase):
    def resolution(self, kind, input_id, code, name="Aus bus", resolution="exact"):
        return {"inputKind": kind, "inputID": input_id, "resolution": resolution, "server": "fb" if code else "",
                "specCode": str(code) if code else "", "acceptedName": name}

    def crosswalk(self, *rows):
        return {cid: {"sourceName": name, "speciesID": sid, "identityStatus": status} for cid, name, sid, status in rows}

    def test_existing_uuid_wins_and_candidates_retire(self):
        existing = [{"id": "app-1", "pack": "TropicalPacific", "scientificName": "Aus bus"}]
        crosswalk = self.crosswalk(("C-1", "Aus bus", "wb-1", "existing_identity"), ("C-2", "Cus dus", "new-2", "new_provisional_identity"))
        rows, report = merge_plan.plan(existing, crosswalk, [self.resolution("existing", "app-1", 1), self.resolution("candidate", "C-1", 1),
                                                             self.resolution("candidate", "C-2", 2, "Cus dus")])
        roles = {r["inputID"]: (r["role"], r["plannedUUID"]) for r in rows}
        self.assertEqual(roles, {"app-1": ("keep", "app-1"), "C-1": ("retire", "app-1"), "C-2": ("keep", "new-2")})
        self.assertEqual((report["status"], report["collisions"], report["retiredUUIDs"]), ("ready", 1, 1))

    def test_workbook_identity_wins_over_new_identities(self):
        crosswalk = self.crosswalk(("C-1", "Aus bus", "new-1", "new_provisional_identity"), ("C-2", "Aus bussa", "wb-2", "existing_identity"))
        rows, _ = merge_plan.plan([], crosswalk, [self.resolution("candidate", "C-1", 1), self.resolution("candidate", "C-2", 1, resolution="synonym")])
        self.assertEqual({r["plannedUUID"] for r in rows}, {"wb-2"})

    def test_record_with_accepted_name_settles_several_existing_records(self):
        existing = [{"id": "app-1", "pack": "TropicalPacific", "scientificName": "Aus oldname"},
                    {"id": "app-2", "pack": "TropicalPacific", "scientificName": "Aus bus"}]
        rows, report = merge_plan.plan(existing, {}, [self.resolution("existing", "app-1", 1, resolution="synonym"), self.resolution("existing", "app-2", 1)])
        self.assertEqual({r["inputID"]: (r["role"], r["plannedUUID"]) for r in rows}, {"app-1": ("retire", "app-2"), "app-2": ("keep", "app-2")})
        self.assertEqual((report["status"], len(report["resolvedByAcceptedName"])), ("ready", 1))

    def test_candidate_with_accepted_name_wins_over_renamed_existing_records(self):
        existing = [{"id": "app-1", "pack": "TropicalPacific", "scientificName": "Apogon fuscus"},
                    {"id": "app-2", "pack": "TropicalPacific", "scientificName": "Apogon guamensis"}]
        crosswalk = self.crosswalk(("C-1", "Nectamia fusca", "new-1", "new_provisional_identity"))
        rows, report = merge_plan.plan(existing, crosswalk, [self.resolution("existing", "app-1", 1, "Nectamia fusca", "synonym"),
                                                             self.resolution("existing", "app-2", 1, "Nectamia fusca", "synonym"),
                                                             self.resolution("candidate", "C-1", 1, "Nectamia fusca")])
        self.assertEqual({r["plannedUUID"] for r in rows}, {"new-1"})
        self.assertEqual(sorted(r["role"] for r in rows), ["keep", "retire", "retire"])
        self.assertEqual(report["status"], "ready")

    def test_several_existing_records_without_the_accepted_name_stop_the_plan(self):
        existing = [{"id": "app-1", "pack": "TropicalPacific", "scientificName": "Aus oldname"},
                    {"id": "app-2", "pack": "TropicalPacific", "scientificName": "Aus othername"}]
        rows, report = merge_plan.plan(existing, {}, [self.resolution("existing", "app-1", 1, resolution="synonym"),
                                                      self.resolution("existing", "app-2", 1, resolution="synonym")])
        self.assertTrue(report["status"].startswith("blocked"))
        self.assertEqual(report["conflicts"][0]["uuids"], ["app-1", "app-2"])
        self.assertEqual({r["role"] for r in rows}, {"conflict"}, "no UUID is chosen for a conflicted taxon")

    def test_one_uuid_for_two_taxa_is_a_conflict(self):
        crosswalk = self.crosswalk(("C-1", "Aus bus", "wb-1", "existing_identity"), ("C-2", "Cus dus", "wb-1", "existing_identity"))
        _, report = merge_plan.plan([], crosswalk, [self.resolution("candidate", "C-1", 1), self.resolution("candidate", "C-2", 2, "Cus dus")])
        self.assertEqual(report["conflicts"][0]["kind"], "one UUID claimed by several taxa")

    def test_unresolved_inputs_are_listed_not_merged(self):
        existing = [{"id": "app-1", "pack": "TropicalPacific", "scientificName": "Opistognathus sp."}]
        rows, report = merge_plan.plan(existing, {}, [self.resolution("existing", "app-1", None, resolution="unresolved")], {"C-1": "pending"})
        self.assertEqual((rows[0]["role"], rows[0]["plannedUUID"]), ("unresolved", ""))
        self.assertEqual((report["unresolvedInputs"]["existing"], report["wormsConfirmedCandidates"], report["confirmedCandidates"]), (1, 0, 0))


if __name__ == "__main__":
    unittest.main()
