import copy
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("catalogue_validation", Path(__file__).with_name("catalogue_validation.py"))
V = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(V)

CLEAN = {
    "id": "r1", "commonName": "Blacktail humbug", "scientificName": "Dascyllus melanurus", "aliases": ["Black-tailed dascyllus"],
    "categories": ["fish"], "colors": ["black", "white"], "markings": ["stripes"], "bodyShapes": ["compressed"], "habitats": ["reef"],
    "behaviors": ["schooling"], "regions": ["pacific"], "subregions": ["Western Central Pacific"],
    "maximumSizeCentimeters": 8.0, "minimumDepthMeters": 1.0, "maximumDepthMeters": 68.0,
    "summary": "A reef-associated fish of the family Pomacentridae, recorded from the Pacific Ocean.",
    "distinguishingFeatures": ["Colours: black and white.", "Dorsal fin: 12 spines, 12–13 soft rays."],
    "typicalHabitat": "Reef-associated; coral reefs; 1–68 m.", "geographicRange": "Pacific Ocean. Recorded from 17 countries and territories.",
    "dataSources": [{"sourceName": "FishBase (v26.06)"}],
}


def with_(**changes):
    record = copy.deepcopy(CLEAN)
    record.update(changes)
    return record


class RiskFlagTests(unittest.TestCase):
    def test_clean_record_has_no_flags_and_scores_zero(self):
        flags = V.risk_flags(CLEAN, ["Adults inhabit sheltered lagoons and harbors in small groups near coral heads."])
        self.assertEqual((flags, V.risk_score(flags)), ([], 0))

    def test_missing_required_fields(self):
        flags = V.risk_flags(with_(geographicRange="", distinguishingFeatures=[], dataSources=[]))
        self.assertEqual([f for f in flags if f.startswith("missing_required")],
                         ["missing_required:distinguishingFeatures", "missing_required:geographicRange", "missing_required:dataSources"])
        self.assertIn("missing_required:summary", V.risk_flags(with_(summary="   ")))

    def test_vocabulary_violations(self):
        self.assertEqual(V.risk_flags(with_(colors=["black", "purple"], habitats=["kelp"])), ["vocabulary:colors", "vocabulary:habitats"])

    def test_size_and_depth_outliers_depend_on_category(self):
        self.assertIn("size_outlier", V.risk_flags(with_(maximumSizeCentimeters=900)))
        self.assertNotIn("size_outlier", V.risk_flags(with_(maximumSizeCentimeters=900, categories=["ray"])), "a 9 m manta is plausible")
        self.assertIn("size_outlier", V.risk_flags(with_(maximumSizeCentimeters=60, categories=["seahorse"])))
        self.assertIn("depth_outlier", V.risk_flags(with_(maximumDepthMeters=5200)))
        self.assertIn("depth_outlier", V.risk_flags(with_(minimumDepthMeters=350, maximumDepthMeters=900)), "never within diving range")
        self.assertEqual(V.risk_flags(with_(maximumSizeCentimeters=None, minimumDepthMeters=None, maximumDepthMeters=None)), [])

    def test_near_verbatim_overlap_with_source_text(self):
        source = "Adults inhabit sheltered lagoons and harbors in small groups near coral heads (Ref. 9)."
        copied = with_(summary="Adults inhabit sheltered lagoons and harbors in small groups near coral heads.",
                       distinguishingFeatures=["Lives in sheltered lagoons and harbors in small groups near coral heads."])
        self.assertEqual(V.risk_flags(copied, [source]), ["near_verbatim:summary", "near_verbatim:distinguishingFeatures"])
        paraphrase = with_(summary="Lives in sheltered lagoons and harbours, in small groups by coral heads.")
        self.assertEqual(V.risk_flags(paraphrase, [source]), [], "seven shared words in a row is not a copy")
        self.assertEqual(V.risk_flags(copied), [], "no source text, no overlap check")

    def test_duplicate_common_names(self):
        self.assertEqual(V.risk_flags(CLEAN, duplicate_common_names={"blacktail humbug"}), ["duplicate_common_name"])

    def test_no_english_common_name(self):
        self.assertEqual(V.risk_flags(with_(commonName="Dascyllus  melanurus")), ["no_english_common_name"])

    def test_ocr_like_junk(self):
        self.assertIn("ocr_junk:commonName", V.risk_flags(with_(commonName="3andspot Cardinalfish")))
        self.assertIn("ocr_junk:geographicRange", V.risk_flags(with_(geographicRange="(Asian Pacific: Bell in Indonesia to $, Japan.")))
        self.assertIn("ocr_junk:aliases", V.risk_flags(with_(aliases=["Black|tail"])))
        fine = with_(summary="Reaches about 30 cm; seen at 1–68 m, the 2nd largest, 10kg.", distinguishingFeatures=["Dorsal fin: 12 spines (rarely 13)."])
        self.assertEqual(V.risk_flags(fine), [], "units, ordinals and balanced brackets are prose")

    def test_distribution_missing(self):
        self.assertEqual(V.risk_flags(with_(regions=[], subregions=[])), ["distribution_missing"])
        self.assertEqual(V.risk_flags(with_(regions=[])), [], "FAO areas alone count as a distribution")

    def test_score_sums_distinct_kinds_and_caps_at_100(self):
        self.assertEqual(V.risk_score(["vocabulary:colors", "vocabulary:habitats"]), 25, "one kind counts once")
        self.assertEqual(V.risk_score(["missing_required:summary", "distribution_missing"]), 45)
        self.assertEqual(V.risk_score(list(V.RISK_WEIGHTS)), 100)

    def test_assess_risk_reports_scores_rates_and_duplicates(self):
        records = [CLEAN, with_(id="r2", scientificName="Dascyllus aruanus"), with_(id="r3", commonName="Queen Angelfish", scientificName="Xus yus", regions=[], subregions=[])]
        report = V.assess_risk(records, {"r1": []}, reserved_common_names=["Queen Angelfish"])
        self.assertEqual(report["records"]["r1"]["flags"], ["duplicate_common_name"])
        self.assertEqual(report["records"]["r3"], {"score": 30, "flags": ["duplicate_common_name", "distribution_missing"]})
        self.assertEqual(report["flagRates"]["duplicate_common_name"], 1.0)
        self.assertEqual(report["flaggedRecords"], 3)
        self.assertEqual(sum(report["scoreHistogram"].values()), 3)


if __name__ == "__main__":
    unittest.main()
