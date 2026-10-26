import json
import unittest

import derive_regions as dr


def record(id, subregions=(), regions=(), status="verified", source="FishBase:SpecCode:1"):
    return {"id": id, "subregions": list(subregions), "regions": list(regions), "categories": ["fish"],
            "review": {"status": status}, "dataSources": [{"stableSourceID": source}]}


def distribution(*countries):
    return {"countries": [{"code": code, "counts": True} for code in countries]}


GLOBAL_MANIFEST = {"id": "global", "packVersion": 24}


def members(records, species):
    outputs = dr.derive(records, species, GLOBAL_MANIFEST, "digest")
    return {directory: set(value[1]["speciesIDs"]) for directory, value in outputs.items()}


class MembershipRuleTests(unittest.TestCase):
    def test_eastern_central_pacific_is_split_by_country(self):
        records = [
            record("hawaii", ["Eastern Central Pacific"], source="FishBase:SpecCode:1"),
            record("galapagos", ["Eastern Central Pacific"], source="FishBase:SpecCode:2"),
            record("both", ["Eastern Central Pacific", "Western Central Pacific"], source="FishBase:SpecCode:3"),
        ]
        species = {"fb:1": distribution("840B"), "fb:2": distribution("218A"), "fb:3": distribution("840B", "I484")}
        result = members(records, species)
        self.assertEqual(result["IndoPacific"], {"hawaii", "both"})
        self.assertEqual(result["PacificCoast"], {"galapagos", "both"}, "a species occurring in both is in both")

    def test_two_coast_countries_need_pacific_evidence(self):
        records = [
            record("gulf", ["Western Central Atlantic", "Eastern Central Pacific"], source="FishBase:SpecCode:1"),
            record("baja", ["Eastern Central Pacific"], source="FishBase:SpecCode:2"),
            record("hawaii-usa", ["Eastern Central Pacific"], source="FishBase:SpecCode:3"),
            record("oregon", ["Northeast Pacific", "Northwest Atlantic"], source="FishBase:SpecCode:4"),
        ]
        species = {"fb:1": distribution("484"), "fb:2": distribution("484"),
                   "fb:3": distribution("840", "840B"), "fb:4": distribution("840")}
        result = members(records, species)
        self.assertEqual(result["PacificCoast"], {"baja", "oregon"})
        self.assertEqual(result["TropicalAtlantic"], {"gulf"})
        self.assertEqual(result["IndoPacific"], {"hawaii-usa"})

    def test_uncounted_countries_are_ignored(self):
        records = [record("stray", ["Eastern Central Pacific"])]
        species = {"fb:1": {"countries": [{"code": "218A", "counts": False}]}}
        self.assertEqual(members(records, species)["PacificCoast"], set())

    def test_mediterranean_and_atlantic_areas(self):
        records = [record("med", ["Mediterranean and Black Sea", "Northeast Atlantic"]),
                   record("brazil", ["Southwest Atlantic"]),
                   record("north-sea", ["Northeast Atlantic"])]
        result = members(records, {})
        self.assertEqual(result["Mediterranean"], {"med"})
        self.assertEqual(result["TropicalAtlantic"], {"brazil"})
        self.assertNotIn("north-sea", set().union(*result.values()), "a temperate-only species stays in Global alone")

    def test_records_without_distribution_use_their_own_locations(self):
        records = [record("queen", [], ["caribbean", "western atlantic", "atlantic"], source="x:source:1"),
                   record("keys", ["Florida Keys"], source="y:source:1")]
        self.assertEqual(members(records, {})["TropicalAtlantic"], {"queen", "keys"})

    def test_manifest_counts_follow_review_status(self):
        records = [record("a", ["Mediterranean and Black Sea"]),
                   record("b", ["Mediterranean and Black Sea"], status="draft")]
        manifest, membership = dr.derive(records, {}, GLOBAL_MANIFEST, "digest")["Mediterranean"]
        self.assertEqual((manifest["includedRecordCount"], manifest["humanReviewedRecordCount"],
                          manifest["publicationEligibleRecordCount"], manifest["speciesCount"]), (2, 1, 1, 2))
        self.assertEqual(manifest["speciesResourceName"], "Members")
        self.assertEqual(membership["sourcePackID"], "global")
        self.assertEqual(membership["speciesIDs"], ["a", "b"])


class CommittedRegionTests(unittest.TestCase):
    def test_committed_regions_match_a_fresh_derivation(self):
        self.assertEqual(dr.main(["--check"]), 0, "run Tools/FishBaseIntake/derive_regions.py")

    def test_every_member_is_a_global_record_and_descriptions_name_places(self):
        global_ids = {r["id"] for r in json.loads((dr.GLOBAL / "Creatures.json").read_text())}
        for region in dr.REGIONS:
            directory = dr.PACKS / region["directory"]
            manifest = json.loads((directory / "PackManifest.json").read_text())
            ids = json.loads((directory / "Members.json").read_text())["speciesIDs"]
            self.assertTrue(set(ids) <= global_ids, region["id"])
            self.assertEqual(len(ids), len(set(ids)))
            self.assertEqual(manifest["speciesCount"], len(ids))
            self.assertGreater(manifest["publicationEligibleRecordCount"], 0)
            self.assertTrue(manifest["geographicScope"])


if __name__ == "__main__":
    unittest.main()
