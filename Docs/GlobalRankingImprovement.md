# Global production ranking: development misses and fixes (2026-10-27)

This records how production search (BM25 retrieval of 50 candidates, then
`LocalSpeciesRanker`) was improved on the Global pack. Every change is a general
linguistic or biological rule; there are no per-case or per-species exceptions.

**These are development cases, and the changes were made while looking at them.** They
are V05Development.v2 and the CaribbeanIdentificationBenchmark development split (the
benchmark holdout and all independent-diver data were never read, run or tuned on). The
results below therefore overstate how well the changes generalise. The independent diver
pilot (`Data/Evaluation/IndependentDiverCollection.md`) is still the real test.

## Evaluation

`GlobalPackEvaluationTests.testProductionRankingOnGlobalDevelopmentCases` runs the 116
development cases (90 identification, 20 no-match, 4 region conflict, 2 ambiguous) against
all 4,798 Global records and writes `Reports/GlobalProductionRankingDevelopment.json`:

```sh
DIVEID_GLOBAL_DEV_RANKING_REPORT="$PWD/Reports/GlobalProductionRankingDevelopment.json" \
  swift test --filter GlobalPackEvaluationTests/testProductionRankingOnGlobalDevelopmentCases
```

The expected species is the case's `expectedSpeciesIDs`, compared by ID (Global carries the
regional packs' IDs). No-match abstention and confidence compliance are hard gates in the test.

Baseline (Global v25, commit `1627391`): expected species first in **52/90**, top-3 61,
top-10 69, in the 50-candidate pool 82/90, 8 identification abstentions, no-match 20/20
abstain, confidence compliance 116/116.

## Every baseline miss, classified (38 of 90)

Each miss has one primary class; secondary factors are noted.

| Class | Misses |
| --- | ---: |
| (a) not retrieved in the BM25 pool | 8 |
| (b) retrieved but out-ranked or rejected | 19 |
| (c) catalogue data problem | 4 |
| (d) parser misses the clue | 7 |

| Case | Class | Expected rank | Pool rank | Top result | Cause |
| --- | --- | --- | --- | --- | --- |
| realistic-004 | a | not in top 10 | – | Blue swimming crab | 'blue swimmer' is an alias of Blue swimming crab; many blue compressed reef fish at Global scale |
| realistic-012 | a | not in top 10 | – | Tailspot coralblenny | 'beaked' is parsed as beak, but BM25 sees the raw word (d) |
| realistic-016 | a | abstained | – | – | 'parrotfish' alone at Global scale: dozens of parrotfishes outrank Stoplight in BM25 |
| realistic-017 | a | not in top 10 | – | Great Barracuda | 'fused teeth' (a parrotfish beak) is not linked to beak (d) |
| realistic-019 | a | not in top 10 | – | Atlantic bigeye | 'beaked' is parsed as beak, but BM25 sees the raw word (d) |
| realistic-027 | a | not in top 10 | – | Red bigeye | Red Lionfish's record does not mention the tentacles above its eyes (c) |
| realistic-038 | a | not in top 10 | – | Scarlet soldierfish | 'toothy' is not linked to teeth (d) |
| v05-10-paraphrase | a | not in top 10 | – | Paletail chromis | Black triggerfish's record has no blue; its pale blue fin-base lines are the described clue (c) |
| realistic-001 | b | 2 | 2 | Blue tuskfish | Blue tuskfish's alias 'Blue-fish' counts as an exact name for 'blue fish' |
| realistic-008 | b | 2 | 31 | Blue tuskfish | Blue tuskfish's alias 'Blue-fish' counts as an exact name for 'blue fish' |
| realistic-029 | b | 2 | 31 | Great Barracuda | Great Barracuda wins on 'solitary'; 'dorsal needles' parsed as spines but lionfish lacks 'solitary' |
| v05-01-paraphrase | b | 2 | 1 | Stoplight Parrotfish | named group 'surgeonfish' (tang) scored as a +1 identity word |
| v05-11-paraphrase | b | 2 | 1 | Spotted Eagle Ray | named group 'triggerfish' scored as a +1 identity word |
| v05-13-diagnostic | b | 2 | 1 | White-patch tuskfish | named group 'surgeonfish' scored as a +1 identity word |
| v05-17-paraphrase | b | 2 | 2 | Leaf scorpionfish | Leaf scorpionfish and Cockatoo waspfish tie on every parsed clue |
| v05-03-paraphrase | b | 3 | 1 | Atlantic Blue Tang | Atlantic Blue Tang and Queen Angelfish share blue/yellow/compressed; the 'crown mark' is not a parsed clue (d) |
| v05-02-paraphrase | b | 4 | 1 | Carolines parrotfish | named group 'parrotfish' scored as a +1 identity word |
| v05-15-diagnostic | b | 4 | 4 | Australian goatfish | named group 'anemonefish' (Fire clownfish) scored as a +1 identity word |
| v05-15-paraphrase | b | 4 | 6 | Barrier reef anemonefish | Barrier reef anemonefish matches every parsed clue equally; tie broken by ordering |
| v05-13-paraphrase | b | 5 | 6 | Orange-lined triggerfish | Orange-lined triggerfish also matches 'oval'; 'mark behind its gill' is not a parsed clue (d) |
| v05-16-diagnostic | b | 7 | 3 | Blackblotch squirrelfish | named group 'anemonefish' scored as a +1 identity word |
| realistic-011 | b | abstained | 1 | – | only colours parsed, so the ranker rejects every candidate despite 'parrotfish' |
| realistic-013 | b | abstained | 1 | – | only colours parsed, so the ranker rejects every candidate despite 'parrotfish' |
| realistic-026 | b | abstained | 1 | – | only a habitat parsed, so the ranker rejects every candidate despite 'lionfish' |
| realistic-036 | b | abstained | 1 | – | only a shape parsed, so the ranker rejects every candidate despite 'barracuda' |
| v05-09-diagnostic | b | not in top 10 | 2 | Roundhead parrotfish | 'birdlike snout' only gives +1 for 'bird'; Bird wrasse has no green colour (c) |
| v05-09-paraphrase | b | not in top 10 | 21 | Rainbow slender wrasse | named group 'wrasse' scored as a +1 identity word; Bird wrasse has no blue/green colour (c) |
| realistic-044 | c | 4 | 1 | Flatback turtle | Green Sea Turtle's record has no 'reef' habitat, so 'reef ledge' is a habitat conflict |
| realistic-024 | c | 7 | 1 | Knobbed porgy | Red Lionfish's record has no 'wreck' habitat (lionfish are common on wrecks), so 'wreck' is a habitat conflict |
| realistic-034 | c | not in top 10 | 2 | Hartzfeld's cardinalfish | Great Barracuda's record has no dark bars/stripes marking |
| v05-05-paraphrase | c | not in top 10 | 1 | Striped rockskipper | Red Lionfish's record has no spotted fins or ledge/hovering behaviour; Striped rockskipper matches stripes+spots |
| v05-08-diagnostic | d | 2 | 1 | Bull ray | 'pointed wings' read as pointed/elongated body; Bull ray's alias 'Duckbill' matches 'duckbill snout' |
| v05-03-diagnostic | d | 10 | 1 | Yellow-spotted triggerfish | 'deep-bodied' is read as deep habitat and a 30 m depth, giving Queen Angelfish a habitat conflict |
| realistic-039 | d | not in top 10 | 2 | Flathead cardinalfish | 'open-water predator' and 'forked tail' are not parsed; Great Barracuda rejected for too little information |
| realistic-045 | d | abstained | 1 | – | 'reptile', 'paddle flippers' and 'grass bed' are not parsed as turtle/seagrass |
| realistic-046 | d | abstained | 1 | – | 'carapace' is not parsed as a turtle clue |
| realistic-048 | d | not in top 10 | 1 | Atlantic Blue Tang | 'smooth shell' is not parsed as a turtle clue; 'small head' is parsed as size 10 |
| realistic-054 | d | abstained | 6 | – | 'wide winged animal' is not parsed as a ray |

Two causes dominate class (b):

- **Named groups are almost ignored (11 cases).** "Parrotfish", "surgeonfish",
  "triggerfish", "anemonefish", "wrasse", "lionfish" and "barracuda" name a family or
  genus. The ranker counts such a word only as a +1 "identity term", because a group
  name "does not name one species". It also rejects a description that the parser rates
  as insufficient (only colours, say) unless it contains an exact name, so
  "heavy reddish brown parrotfish with pale markings" returned nothing.
- **A non-distinctive alias counts as an exact name (2 cases).** Blue tuskfish's
  alias "Blue-fish" normalises to "blue fish", so any "blue fish" description gets the
  +20 exact-name score.

## Plan

Largest classes first, one rule per commit, each rerun against these gates (reverted
otherwise): no-match 20/20 abstain; region-conflict and ambiguous behaviour unchanged;
confidence compliance 100%; V05 regional gates (Caribbean 16/16, Tropical Pacific 18/18)
and `SearchGoldenOrderingTests` pass; no previously correct top-1 regresses without an
explanation.

1. (b) Named groups count as evidence.
2. (b) Trait-plus-"fish" aliases are not names.
3. (d) Parser vocabulary for the misread clues.
4. (c) Record problems are listed for review, not edited here.

## Changes and results

Each change was rerun against the gates before it was committed. All gates hold after every
commit: no-match 20/20 abstain; confidence compliance 116/116; region-conflict cases
unchanged; V05 regional gates unchanged in kind (top-10 34/34 in development; no-match 6/6,
region conflicts 4/4, ambiguous 2/2, confidence 46/46 in both access modes);
`SearchGoldenOrderingTests` pass against a golden regenerated for each intended change (the
header records what changed each time).

| Commit | Rule | Top-1 | Top-3 | Top-10 | Pool recall | Abstained |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `1627391` | Baseline | 52 | 61 | 69 | 82 | 8 |
| `af70c27` | A named group ("parrotfish") is evidence for its members (+6, like a category); tang = surgeonfish, clownfish = anemonefish; "fish" is never a group | 58 | 67 | 73 | 82 | 3 |
| `9921405` | A trait word plus "fish" ("Blue-fish") is not a species name | 60 | 67 | 73 | 82 | 3 |
| `6ac88d4` | Parser: a shape/size word before a body part describes that part; "deep-bodied" is a body shape; toothy, fused teeth, reptile, carapace, flipper, winged, grass bed | 66 | 72 | 78 | 82 | 0 |
| `3b13fdd` | BM25 also searches the catalogue terms the parser recognised ("beaked" → beak) | **69** | **75** | **81** | **85** | **0** |

All counts are of the 90 identification cases. No-match stays 20/20 abstain throughout.

**Behaviour changes outside identification**

- The ambiguous case `v05-ambiguous-trigger` ("Dark triggerfish …") now shows a
  triggerfish first instead of French Angelfish, because the description names the group.
  It still passes the ambiguous gate (confidence ≤ 0.64, an acceptable species in the top ten).
- One previously correct top-1 regressed, with this explanation: `realistic-009` ("reef
  grazer that was blue except for its tail spine") loses Atlantic Blue Tang from the pool
  after `3b13fdd`. "Grazer" now adds "grazing", which lifts the many grazing surgeonfishes,
  while the carried Atlantic Blue Tang record lists only "swimming" and has no spine. That
  record gap is listed below.

**The four named misses**

| Case | Before | After | Why |
| --- | --- | --- | --- |
| v05-05-paraphrase (Red Lionfish) | not in top 10 | not in top 10 | record has no spotted fins and no ledge/hovering clue matching "hanging motionless beneath a rocky ledge" |
| v05-09-diagnostic (Bird wrasse) | not in top 10 | **rank 9** | record has no colours at all, so "green" cannot match |
| v05-09-paraphrase (Bird wrasse) | not in top 10 | not in top 10 | same: no blue or green in the record |
| v05-10-paraphrase (Black triggerfish) | not in top 10 | not in top 10 | record has no blue for its pale blue fin-base lines |

None of the four can be fixed by a general ranking rule; each needs the record reviewed.

**Remaining misses (21) by original class:** (b) 9, (c) 5 (including `realistic-009`),
(a) 5, (d) 2. Fixed: (b) 10, (d) 5, (a) 3. The (b) misses left are mostly near-ties, where
two species match every parsed clue equally (`v05-15-*`, `v05-17-paraphrase`), so there is no
principled tie-breaker.

## Catalogue records to review

Listed for the owner's review; no generated record was edited. A fix should go through the
validated overlay/import path (`Tools/FishBaseIntake`, then `publish_global.py` and
`derive_regions.py`) and a batch review, so the change is recorded and approved.

| Record | Problem | Cases affected |
| --- | --- | --- |
| The 8 carried Caribbean records (Atlantic Blue Tang, Stoplight Parrotfish, Red Lionfish, Great Barracuda, Green Sea Turtle, Spotted Eagle Ray, Queen Angelfish, French Angelfish) | No taxonomy (family/order null) and only slug aliases (`atlantic-blue-tang`), unlike the 4,790 FishBase-built records | many benchmark cases |
| Atlantic Blue Tang | Behaviours list only "swimming" (it grazes); no caudal spine marking | realistic-009 |
| Black triggerfish | No blue colour: pale blue lines along the dorsal and anal fin bases are diagnostic | v05-10-paraphrase |
| Bird wrasse | No colours (males green to blue-green) | v05-09-diagnostic, v05-09-paraphrase |
| Red Lionfish | No spots (spotted fin membranes); no tentacles above the eyes; no "wreck" habitat | v05-05-paraphrase, realistic-027, realistic-024 |
| Green Sea Turtle | No "reef" habitat (rests under reef ledges) | realistic-044 |
| Great Barracuda | No dark bars along the side; no open-water habitat | realistic-034, realistic-039 |
| Stoplight Parrotfish | No orange among the terminal-phase colours | realistic-016 |

## Caveat

The 116 cases are development cases, and every rule above was chosen while looking at
them, so the gains overstate what users will see. They are general rules, not per-case
fixes, but only the independent diver pilot can show whether they generalise.
