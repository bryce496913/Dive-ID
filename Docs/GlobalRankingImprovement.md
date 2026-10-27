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
