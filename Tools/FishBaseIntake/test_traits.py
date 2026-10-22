"""Focused tests for trait extraction (traits.py). Passages are short synthetic sentences
in FishBase style; no network."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import traits  # noqa: E402

D, B = "morphdat.AddChars", "species.Comments"


def x(description="", biology="", rules=traits.RULES):
    return traits.extract({D: description, B: biology}, rules)


class NegationTests(unittest.TestCase):
    def test_without_no_lacks_and_absent_do_not_assert_the_trait(self):
        for text in ("Body silvery without spots.", "No spots on the body.", "Body lacks spots.", "Lateral spots absent.", "Never spotted."):
            with self.subTest(text=text):
                self.assertNotIn("spots", x(text)["main"].markings)
        self.assertIn("spots", x("Body with black spots.")["main"].markings)

    def test_negation_scope_is_local(self):
        result = x("Without spots, but with dark bars on the flank.")
        self.assertNotIn("spots", result["main"].markings)
        self.assertIn("stripes", result["main"].markings)

    def test_negated_clue_patterns_are_not_asserted(self):
        self.assertEqual(x("Small juveniles lack the elongate snout.")["variants"], {})
        self.assertNotIn("Long snout", x("Adult without a long snout.")["main"].head)
        self.assertIn("Long snout", x("Identified by long snout when adult.")["main"].head)

    def test_rule_can_be_disabled_for_reporting(self):
        self.assertIn("spots", x("Body without spots.", rules=traits.RULES - {"negation"})["main"].markings)


class LifeStageAndSexTests(unittest.TestCase):
    def test_juvenile_traits_go_to_a_juvenile_variant_not_the_main_profile(self):
        result = x("Body of adult dark grayish brown; juveniles yellow.")
        self.assertEqual(result["main"].colors, {"gray", "brown"})
        self.assertEqual(result["variants"]["juvenile"].colors, {"yellow"})

    def test_male_and_female_traits_go_to_separate_variants(self):
        result = x("Juveniles and males bright red, females become maroon to nearly black.")
        self.assertEqual(result["main"].colors, set())
        self.assertEqual(result["variants"]["juvenile"].colors, {"red"})
        self.assertEqual(result["variants"]["male"].colors, {"red"})
        self.assertEqual(result["variants"]["female"].colors, {"black"})

    def test_adult_clauses_feed_the_main_profile(self):
        result = x("Adults orange with a vertical black-edged bluish white band behind the eye.")
        self.assertEqual(result["variants"], {})
        self.assertIn("White band behind the eye, black-edged", result["main"].head)

    def test_biology_qualifiers_apply_too(self):
        result = x(biology="Adults usually form schools. Juveniles solitary and secretive on shallow rubble.")
        self.assertEqual(result["main"].behaviors, {"schooling"})
        self.assertEqual(result["main"].habitats, set())
        self.assertEqual(result["variants"]["juvenile"].behaviors, {"solitary"})
        self.assertEqual(result["variants"]["juvenile"].habitats, {"rubble"})

    def test_stage_rule_can_be_disabled_for_reporting(self):
        self.assertIn("yellow", x("Juveniles yellow.", rules=traits.RULES - {"stage"})["main"].colors)

    def test_sexes_alike_statement_asserts_nothing(self):
        self.assertEqual(x("Males alike females.")["flags"], [])


class AmbiguityTests(unittest.TestCase):
    def test_hedged_passage_is_flagged_and_not_asserted(self):
        result = x("Body may also be black along with pelvic and anal fins.")
        self.assertNotIn("black", result["main"].colors)
        self.assertEqual(result["flags"], ["trait_ambiguous:colors"])
        for text in ("Sometimes with dark spots.", "With or without spots."):
            with self.subTest(text=text):
                r = x(text)
                self.assertNotIn("spots", r["main"].markings)
                self.assertTrue(any(f.startswith("trait_ambiguous") for f in r["flags"]))

    def test_comparing_sexes_or_stages_is_flagged(self):
        result = x("Males have brighter red color than females.")
        self.assertEqual((result["main"].colors, result["variants"]), (set(), {}))
        self.assertEqual(result["flags"], ["trait_ambiguous:colors"])
        compared = x("Juveniles more spotted than adults.")
        self.assertEqual((compared["main"].markings, compared["flags"]), (set(), ["trait_ambiguous:markings"]))

    def test_an_observation_is_not_a_hedge(self):
        result = x(biology="A strongly compressed fish that can be seen rocking back and forth on the bottom in response to surge.")
        self.assertIn("Sways back and forth with the surge", result["main"].features)
        self.assertEqual(result["flags"], [])

    def test_hedge_rule_can_be_disabled_for_reporting(self):
        self.assertIn("black", x("Body may be black.", rules=traits.RULES - {"hedge"})["main"].colors)


class CluePatternTests(unittest.TestCase):
    def test_head_clues(self):
        head = x("Teeth red; front of eye with deep groove; upturned mouth, protruding chin; snout and forehead abruptly white; "
                 "a distinctive prominent preopercular spine that extends across the head-bar.")["main"].head
        for clue in ("Red teeth", "Deep groove in front of the eye", "Upturned mouth", "Protruding chin",
                     "White snout and forehead", "Prominent cheek spine", "Bar across the head"):
            self.assertIn(clue, head)

    def test_fin_colours_margins_and_shapes(self):
        result = x("Yellowish snout and pectoral fins; dorsal and anal fins white with black margins; caudal fin pink with white base; "
                   "second dorsal spine longest; lunate caudal fin, prolonged lobes in large adult.")
        fins = result["main"].fins
        for clue in ("Yellow pectoral fins", "White dorsal and anal fins", "Black margins on the dorsal and anal fins",
                     "Tall front dorsal fin", "Long tail lobes"):
            self.assertIn(clue, fins)
        self.assertIn("Yellow snout", result["main"].head)
        self.assertIn("fin edge", result["main"].markings)
        self.assertIn("lunate", result["main"].tail_shapes)
        self.assertIn("Black pelvic fins", x("Distinguished by the black ventral fins.")["main"].fins)

    def test_false_positives_found_in_review_stay_fixed(self):
        timor = x("Axil of pectoral fin black. Young with a black saddle preceded by a pearly-white border on upper edge of caudal peduncle.")
        self.assertEqual(timor["main"].fins, ["Black base of the pectoral fins"])
        self.assertNotIn("fin edge", timor["variants"]["juvenile"].markings, "a saddle's border is not a fin margin")
        self.assertEqual(x("Long snout; projecting lower jaw.")["main"].head, ["Long snout", "Projecting lower jaw"])
        self.assertIn("Blue margins on the dorsal fin and tail", x("Dorsal and caudal fins with blue margins.")["main"].fins)
        self.assertIn("Mimics Meiacanthus", x(biology="Juveniles and adults mimic Meiacanthus species.")["main"].features + x(biology="Mimics Meiacanthus atrodorsalis.")["main"].features)

    def test_body_pattern_features(self):
        features = x("Alternating black-edged blue and yellow stripes. Posterior to upper end of gill opening is a bright orange "
                     "horizontal band, with purplish black border. Head and anterior half of body abruptly paler than the posterior half. "
                     "A lancet-like spine on each side of caudal peduncle.")["main"]
        self.assertIn("Blue and yellow stripes with black edges", features.features)
        self.assertIn("Orange band behind the gill opening", features.features)
        self.assertIn("Front half paler than the rear", features.features)
        self.assertNotIn("Black margins", features.features, "a band's border is not a fin margin")
        self.assertIn("Sharp spine on each side of the tail base", features.fins)

    def test_behaviour_and_habitat_clues(self):
        result = x(biology="Inhabits shallow areas with sand rubble and weed. Solitary or in pairs. Nocturnal. Form large schools to feed. "
                           "Associated with the anemone Entacmaea quadricolor. Forms spawning aggregations.")
        self.assertEqual(result["main"].habitats, {"sand", "rubble", "anemone"})
        self.assertEqual(result["main"].behaviors, {"solitary", "schooling", "anemone association"})
        self.assertIn("Often seen in pairs", result["main"].features)
        self.assertIn("Active at night", result["main"].features)
        self.assertNotIn("schooling", x(biology="Forms spawning aggregations.")["main"].behaviors)

    def test_html_and_references_are_stripped(self):
        result = x(biology='Associated with the anemones: <a href=http://x.org/a?b=c><i>Entacmaea quadricolor</i></a> (Ref. 5911).')
        self.assertEqual(result["main"].habitats, {"anemone"})

    def test_every_value_is_traced_to_its_source_field(self):
        result = x("Juveniles yellow.", "A solitary species.")
        self.assertIn({"target": "juvenile", "kind": "colors", "value": "yellow", "source": D}, result["trace"])
        self.assertIn({"target": "main", "kind": "behaviors", "value": "solitary", "source": B}, result["trace"])


if __name__ == "__main__":
    unittest.main()
