# Global pack: search quality and performance at full size (2026-10-22)

The Global pack now holds **4,786 draft records** (Debug only; Release excludes it).
This page reports how search behaves on it. **Two blocking results: Tropical Pacific
gates regress, and query latency is unacceptable.** Per the owner's instruction,
nothing was retuned; causes and options are below.

## How it was measured

- **Quality:** `GlobalPackEvaluationTests.testFrozenV05CasesAgainstTheGlobalPack`.
  - It runs the frozen V05 v2 cases (unchanged) through `LocalMarineLifeIdentificationService`
    with the Global pack. A retired UUID counts as the UUID the merge plan kept.
  - Gates use the frozen floors in `Data/Evaluation/V05Protocol.v2.json`.
  - Opt-in: `DIVEID_GLOBAL_EVAL_REPORT=<file> swift test -c release --filter GlobalPackEvaluationTests`.
- **Location clues:** `testOutOfRangeLocationCluesStillReturnTheSpecies`, with
  `DiveIDTests/Fixtures/GlobalLocation.v1.json` (6 cases). Each description is run with
  and without a location outside the species' recorded range.
- **Performance:** `GlobalPackPerformanceTests`.
  - Release configuration, Linux, 4 cores, Swift 6.1.
  - Per pack: catalogue load ×5, search-document build ×3, BM25 retrieval ×10, and
    46 V05 queries ×3 through the production engine.
  - Reported as median and nearest-rank p95. Memory is VmRSS/VmHWM.
  - Opt-in: `DIVEID_PERF_REPORT=<file> swift test -c release --filter GlobalPackPerformanceTests`.
  - These are **host-side proxies**, not the iPhone search-to-visible measurement in
    [V05CandidateValidation.md](V05CandidateValidation.md#actual-iphone-latency-and-memory-protocol-no-measurements-yet).
    No device timings exist.

Raw results: [`Reports/GlobalPackEvaluation.json`](../Reports/GlobalPackEvaluation.json) and
[`Reports/GlobalPackPerformance.release.json`](../Reports/GlobalPackPerformance.release.json).

## Quality

### Regional gates (before and after)

Production engine, all 46 cases, Debug and Release. The results are identical
before (`d7bc2f4`) and after this change:

| Metric | Value | Floor |
| --- | --- | --- |
| top1 | 27/34 | 0.4 |
| top3 | 33/34 | 0.6 |
| top10 | 34/34 | 0.8 |
| candidate recall | 34/34 | 0.85 |
| no-match | 6/6 | 1.0 |
| region conflict | 4/4 | 1.0 |
| confidence | 46/46 | 1.0 |

### Same cases against Global

The Caribbean cases expect the 8 Caribbean records, which are not in Global. They are
therefore evaluated two ways: against Global as written, and against Global plus the
8 records, assembled in memory only.

| Variant | Records | top1 | top3 | top10 | No-match | Confidence |
| --- | --- | --- | --- | --- | --- | --- |
| Tropical Pacific, regional pack (before) | 1,000 | 13/18 | 17/18 | 18/18 | 3/3 | 24/24 |
| **Global as written** (Tropical Pacific cases) | 4,786 | **4/18** | **7/18** | **8/18** | 6/6 | **28/29** |
| Global records for the Tropical Pacific IDs (diagnostic) | 962 | 6/18 | 7/18 | 9/18 | 6/6 | 28/29 |
| Caribbean, regional pack (before) | 8 | 14/16 | 16/16 | 16/16 | 3/3 | 22/22 |
| Global + Caribbean 8 (Caribbean cases) | 4,794 | 10/16 | 12/16 | 14/16 | 3/3 | see all cases |
| **Global + Caribbean 8** (all cases) | 4,794 | 14/34 | 19/34 | **22/34** | 6/6 | **44/46** |

- **Tropical Pacific fails top10 (0.44 < 0.8), top3 and confidence.** The Caribbean
  cases cannot run against Global as written (17 cases blocked).
- **Region-conflict cases do not apply to Global.** It has no region aliases, so a
  described location never blocks a search. All 4 return results.

**Cause: the rebuilt record text, not the pack size.** At regional size (962 records),
Global's records score nearly as badly (9/18) as the full pack (8/18). The regional
records carried field-guide wording that divers paraphrase: "sways like a leaf",
"high front dorsal fin". The rebuilt records have short factual text built from
FishBase fields: family, depth, fin counts, colour words. Example, Cockatoo waspfish:

- **Query:** "Brown compressed fish swaying like a leaf above rubble, high front
  dorsal fin."
- **Regional record:** "…Laterally compressed body with raised anterior dorsal spines;
  sways with the surge to mimic drifting leaves…"
- **Global record:** "A near-bottom fish of the family Tetrarogidae… Colours: brown, gray,
  red and white. Body shape: compressed. Dorsal fin: 17–18 spines…"

Going to full size then adds competitors (top1 6 → 4).

### Location clues (out-of-range species)

Checked against [the ranking contract](HybridRankingContract.md#location): location
never filters, and the −3 out-of-range penalty applies only after eligibility, so it
never removes a candidate. The contract caps results at ten and promises nothing
about display.

`testOutOfRangeLocationCluesStillReturnTheSpecies` therefore checks two things:
- **Pool:** the species stays in the retrieved pool (BM25 top 50) when a location is added.
- **Eligibility:** with the out-of-range clue, the species stays eligible, its evidence
  score and confidence are unchanged, and its ordering is exactly 3 lower than with
  no location.

Display in the top ten is measured and reported, not asserted.

| Case | Species | Out-of-range clue | Pool rank | Displayed without | Displayed with |
| --- | --- | --- | --- | --- | --- |
| clown-triggerfish-caribbean | *Balistoides conspicillum* | Caribbean | 8 | #10 | **no** |
| clown-anemonefish-belize | *Amphiprion ocellaris* | Belize | 5 | #3 | #4 |
| regal-angelfish-bonaire | *Pygoplites diacanthus* | Bonaire | 3 | #3 | #7 |
| queen-triggerfish-fiji | *Balistes vetula* | Fiji | 26 | #2 | #5 |
| moorish-idol-florida | *Zanclus cornutus* | Florida | not retrieved | no | no |
| spanish-hogfish-hawaii | *Bodianus rufus* | Hawaii | not retrieved | no | no |

- **The policy holds for all 4 applicable cases.** The test passes.
- **The Clown triggerfish leaves the displayed ten** under the −3 penalty. The contract
  allows this.
- **The Moorish idol and Spanish hogfish cannot test location.** They are not
  retrieved even without one, which is the text cause above. They are reported as
  inapplicable.
- The test requires at least 4 applicable cases, so it cannot pass on nothing. A
  temporary mutation that removed out-of-range candidates failed all 4.

## Asserted gate baseline (2026-10-22)

`testFrozenV05CasesAgainstTheGlobalPack` asserts every frozen V05 v2 floor on the pack
as written, so it failed when it ran (it passes since builder v4; see
[the negation repair and ranking fix](#negation-repair-and-ranking-fix-builder-v4-2026-10-22)). It is still opt-in, through
`DIVEID_GLOBAL_EVAL_REPORT`. Run in Release on Linux, the opt-in test takes 443 s:

| Gate | Global as written (v2 → v3) | Floor | Status |
| --- | --- | --- | --- |
| candidateRecall (BM25 top 50) | 14/18 → 16/18 = 0.889 | 0.85 | passed |
| top1 | 4/18 → 5/18 = 0.278 | 0.4 | **failed** |
| top3 | 7/18 → 8/18 = 0.444 | 0.6 | **failed** |
| top10 | 8/18 → 12/18 = 0.667 | 0.8 | **failed** |
| noMatchCorrect | 6/6 | 1.0 | passed |
| confidenceCompliant | 28/29 = 0.966 | 1.0 | **failed**: `v05-ambiguous-trigger` scores 0.643 against its 0.64 ceiling |
| regionConflictCorrect | none | 1.0 | not applicable |

- **Region conflicts:** a single Global pack has no region aliases, so a described
  location never mismatches it; it ranks instead. Any other gate with no applicable case fails
  as "not evaluated", except this one gate.
- **Positive cases:** these are the 18 Tropical Pacific identification cases. The 17
  Caribbean cases are blocked by coverage, because their expected records are not in
  Global.
- **Unchanged:** floors and frozen expectations. Content and the size rule changed
  in builder v3 (above).
- **Default region:** new installs start in Caribbean, and existing selections
  (Global included) are kept, until these gates pass.

## Readiness report (2026-10-22, `main` at `2766a55`)

**Verdict: Global does not meet the bar to become the default and main search
experience.** It fails four of the six applicable V05 gates on its full development
catalogue, and Release contains no approved Global record, so there is nothing to
ship. Regional packs remain the default (Caribbean for new installs).

All runs below are host runs (Linux, Swift 6.1). Debug and Release produced identical
gate results. These are search-quality results, not device results.

### Gates per configuration (V05 v2 floors)

| Gate (floor) | (a) Full Global, development (4,786) | (b) Release-approved Global (0) | (c) Regional, development (8 + 1,000) | (c) Regional, Release (2 Caribbean) |
| --- | --- | --- | --- | --- |
| candidateRecall (0.85) | 16/18 **pass** | not evaluated | 34/34 pass | 4/4 pass |
| top1 (0.4) | 5/18 **fail** | not evaluated | 27/34 pass | 3/4 pass |
| top3 (0.6) | 8/18 **fail** | not evaluated | 33/34 pass | 4/4 pass |
| top10 (0.8) | 12/18 **fail** | not evaluated | 34/34 pass | 4/4 pass |
| noMatchCorrect (1.0) | 6/6 pass | not evaluated | 6/6 pass | 3/3 pass |
| confidenceCompliant (1.0) | 28/29 **fail** | not evaluated | 46/46 pass | 10/10 pass |
| regionConflictCorrect (1.0) | not applicable (no region aliases) | not applicable | 4/4 pass | 2/2 pass |
| Cases out of scope | 17 (Caribbean targets not in Global) | **46 of 46** | 0 | 36 of 46 |

Per region, the regional development baseline scores:

| Region | top1 | top3 | top10 |
| --- | --- | --- | --- |
| Caribbean | 14/16 | 16/16 | 16/16 |
| Tropical Pacific | 13/18 | 17/18 | 18/18 |

Global scores 5/18, 8/18 and 12/18 on those same Tropical Pacific cases.

Sources: the opt-in `GlobalPackEvaluationTests` (variants `global-as-written` and
`global-release-approved`) and `Tools/Evaluation/run_v05.py`, Debug and Release.

### Out of scope in the small Release catalogues

A small catalogue cannot look better or worse than it is: a case is out of scope when
its target species is not in the catalogue. An empty catalogue evaluates nothing, so
it cannot pass no-match cases by returning nothing.

- **Release-approved Global (0 records):** all 46 cases are out of scope.
  - Batch 1's 250 approvals lapsed in the builder v3 rebuild; `batch-01-rereview`
    awaits review.
  - The other 4,536 records have never been reviewed.
- **Release Caribbean (2 records):** 10 cases are in scope:
  - v05-01 and v05-03, diagnostic and paraphrase (Atlantic Blue Tang and Queen
    Angelfish);
  - v05-ambiguous-angelfish;
  - the 3 Caribbean no-match cases;
  - v05-region-1 and v05-region-2.

  The other 36 are out of scope: 12 Caribbean cases whose targets are draft, and all
  24 Tropical Pacific cases. Its 4/4 positives show that search works for the 2
  approved species; they do not show coverage.
- **What-if, not approved: batch 1's 250 records** (`global-batch-01-pending`).
  - **In scope:** 17 cases. The positives are only v05-09, 10 and 17 (Bird wrasse,
    Black triggerfish, Cockatoo waspfish), so 6 positive cases; 29 cases are out of
    scope.
  - **Results:** recall 5/6, top1 3/6, top3 3/6, top10 3/6, no-match 6/6, confidence
    17/17.
  - **Caution:** this shows what approving batch 1 would expose; it is not a Release
    result.

### What still blocks Global as the default

1. **Search quality on the full catalogue.** *Update (builder v4): the gates now pass
   on the development catalogue (top1 9/18, top3 11/18, top10 15/18, confidence
   29/29); see [the negation repair and ranking fix](#negation-repair-and-ranking-fix-builder-v4-2026-10-22).
   Release still has no approved Global record.* At the time of this report, top1
   5/18, top3 8/18 and top10 12/18 were below 0.4, 0.6 and 0.8. Confidence fails on `v05-ambiguous-trigger` (0.643
   against a 0.64 ceiling). The remaining causes, which need owner decisions:
   - **Generic aliases:** 65 records carry a bare group word ("Surgeonfish") that
     counts as an exact name.
   - **Variant scoring:** appearance-variant scores add to the main colour score.
   - **Clues with no source:** some lost clues can't be recovered from the source.
2. **Caribbean coverage.** The 8 Caribbean records, including the 2 approved ones, are
   not in Global, so 17 Caribbean cases cannot run against it. Global plus those 8
   (in memory) scores top10 26/34, still below 0.8.
3. **No approved Global record.** Release would show no Global pack. The
   `batch-01-rereview` decision is pending, and 4,536 records await review.
4. **Search behaviour still to decide.** One parser nondeterminism ("sandy" →
   "bottom-swimming" in some processes) changes one golden query's ranking between
   runs.
5. **Device evidence.** No iPhone measurements exist; the checklist is in
   [V05CandidateValidation.md](V05CandidateValidation.md#release-device-checklist-prepared-2026-10-22-unexecuted).
   - **Host only:** the first Global query takes about 5.9 s (index build) and warm
     queries about 103 ms median. *Update: see
     [cold index loading](#cold-index-loading-2026-10-22).*
6. **Xcode tests.** The Xcode build, unit and UI tests have not run in this
   environment. The SwiftUI code (credits screen, source links) has never been
   compiled.

### Checks run for this report

- **Python:** all 8 suites in the README's portable checks pass.
- **`swift test` and `swift test -c release`:** 172 tests, 5 skipped, 0 failures.
- **`run_v05.py`**, Debug and Release: every regional gate passes, development and
  publication.
- **Opt-in Global evaluation**, Debug and Release: fails on top1, top3, top10 and
  confidence, as shown above.

## Evidence rebuild and size fix (builder v3, 2026-10-22; findings P1, P3, P4)

### What the rebuild lost, case by case

These are the clues each Tropical Pacific case relies on that the regional record
carried and the v2 Global record did not. A clue is "recovered" when FishBase
supports it; the source field for each one is in `DiveIDTests/Fixtures/GlobalEvidence.v1.json`.

| Species (cases) | Lost clue and field (v2) | v3 |
| --- | --- | --- |
| Cockatoo waspfish (17) | swaying with the surge (features); tall front dorsal fin (finAndSpineClues); rubble, sand (habitats); solitary (behaviors); leaf-like (features) | all recovered except **leaf**: FishBase never describes leaf mimicry |
| Bird wrasse (09) | long snout (head); solitary (behaviors); green and blue (colors) | snout and solitary recovered; **colours have no source** |
| Black triggerfish (10) | groove in front of the eye; groups (behaviors); pale lines at the fin bases | first two recovered; **fin-base lines have no source** |
| Pinktail triggerfish (11) | pink tail; yellow pectoral fins; black fin margins; juvenile eye lines | all recovered (eye lines as a juvenile variant) |
| Red-toothed triggerfish (12) | lunate tail and long lobes; red teeth; schooling | all recovered |
| Orangespot surgeonfish (13) | orange band behind the gill opening; front half paler; yellow wrongly in adult colours | recovered; yellow moved to the juvenile variant |
| Lined surgeonfish (14) | black-edged blue and yellow stripes; tail spine; schooling (adults) | recovered; juvenile solitary moved to a variant |
| Fire clownfish (15) | white band behind the eye; black pelvic fins; anemone; red juveniles | all recovered |
| Spinecheek anemonefish (16) | cheek spine; anemone; male red, female dark | all recovered; **three white bars have no source** |

### Extraction rules: records changed

Each count is the number of the 4,787 drafts whose traits change when that rule is
switched off. They come from `Data/GlobalMarine/FishBase/BuildReport.json`.

| Rule | Records changed |
| --- | --- |
| Life stage and sex: juvenile, male and female traits go to appearance variants | 827 |
| Hedge: "may", "sometimes", "with or without" assert nothing | 634 |
| Negation: "without", "no", "lacks", "absent" | 164 |

- **Variants:** 493 records now have juvenile variants, 249 male and 154 female.
- **Ambiguity flags:** 918 records carry a `trait_ambiguous` risk flag. This includes
  coded and described tail shapes that disagree; neither shape is then asserted.
- **Changes from v2:**
  - colours in 558 records, markings 1,293, habitats 1,597, behaviours 1,108;
  - tail shape 387, head clues 253, fin clues 551;
  - appearance variants 714, features 2,327.

### Size

Maximum-only records are now compared (see the
[ranking contract](HybridRankingContract.md#size)). Widths are never compared as
lengths.

### Results before and after (Release)

| Variant | Records | Recall | top1 | top3 | top10 | Confidence |
| --- | --- | --- | --- | --- | --- | --- |
| Global, 18 Tropical Pacific cases (before) | 4,786 | 14/18 | 4/18 | 7/18 | 8/18 | 28/29 |
| **Global, 18 Tropical Pacific cases (after)** | 4,786 | **16/18** | **5/18** | **8/18** | **12/18** | 28/29 |
| Rebuilt regional records only (before) | 962 | 15/18 | 6/18 | 7/18 | 9/18 | 28/29 |
| **Rebuilt regional records only (after)** | 962 | **17/18** | 6/18 | **9/18** | **14/18** | 28/29 |
| Global + Caribbean 8, all 46 cases (before) | 4,794 | 30/34 | 14/34 | 19/34 | 22/34 | 44/46 |
| **Global + Caribbean 8, all 46 cases (after)** | 4,794 | **32/34** | 13/34 | 17/34 | **26/34** | 44/46 |

**Regional packs:** all V05 gates still pass, in Debug and Release. Expected-species
ranks are unchanged. The size fix reorders some lower results; the structured
engine's top-1 rises from 23 to 24.

**Global gates that still fail:** top1 (5/18 against 0.4), top3 (8/18 against 0.6),
top10 (12/18 against 0.8) and confidence (28/29). Candidate recall now passes (16/18).

Remaining causes, found by inspecting the regressed Lined surgeonfish cases (#1 → #9 and #5 → out):

- **Generic aliases.** 65 Global records carry a bare group word as an alias, such as
  "Surgeonfish" or "Wrasse", taken from FishBase's English common names. Any
  description that mentions the group then counts as an exact-name match for every
  one of them. This predates this pass.
- **Variant scoring adds to the main colours.** A matching appearance variant adds
  up to +6 on top of main-profile colour matches, and many more records now have
  variants. Changing this is a ranking change.
- **Clues with no source:** Bird wrasse colours, Black triggerfish fin-base lines and
  Spinecheek bar count.

## Negation repair and ranking fix (builder v4, 2026-10-22)

**The opt-in Global evaluation now passes every applicable gate,** and exits 0. Its
cases, expected and acceptable identities, rank bounds, candidate limit, floors,
denominators and splits are unchanged. These cases were used to find the defects, so
the result is development evidence, not a held-out measurement.

### What changed

1. **Negation in extraction** (`Tools/FishBaseIntake/traits.py`, builder v4). The
   three-word window was replaced by a bounded scope, which:
   - runs over a negated clause and over a coordinated list ("no blue, red, yellow or
     white spots");
   - stops at a contrast ("but", "however"), a life-stage word, another negator, a
     new predicate ("and is nocturnal"), a spaced dash or a comma that starts a new
     trait;
   - also handles postfix negators ("spots absent").
   - When the end of a scope is uncertain, it flags the record
     (`trait_ambiguous:negation_scope`) and asserts nothing.
   - Every branch now uses it: diagnostic phrases (gill-opening spot), habitat
     normalisation (sea grass, drop-off) and every match of the fin-colour rule.
   - `Data/GlobalMarine/FishBase/ExtractionAudit.json` lists the 184 real records
     whose traits changed: 51 from the negation scope, 133 from comma boundaries that
     previously joined one fin's colour to the next fin. Synthetic probes are kept
     separately in `test_traits.py`.
2. **Ranking** ([contract](HybridRankingContract.md#group-names-and-appearance-variants-2026-10-22)):
   - group names and hyphenated compounds no longer count as exact names;
   - appearance variants count only clues the main profile has not already matched,
     and only for a stage compatible with the one described;
   - coordinated colours before a marking, and a front-to-rear contrast, are
     appearance relationships;
   - "maroon" is red, and "-like" words yield their stem.

No catalogue fact was added by hand. The regenerated drafts and pack went through
`build.py` and `publish_global.py`. IDs and provenance are unchanged, and the paired
pack files were written together. All 250 batch-01 approvals are still lapsed
(`AppliedApprovals.json`: 0 approved, 250 stale), and Release still exposes no Global
record. The 87 flagged records, the 30-record sample and the 133 unread records of
batch 1 are in a new re-review manifest, `batch-01-rereview` generation 2.

### Gates (Global as written, 4,786 records, 18 Tropical Pacific cases)

| Gate | Floor | Before (`dff58fd`) | After |
| --- | --- | --- | --- |
| candidateRecall | 0.85 | 16/18 | 17/18 |
| top1 | 0.4 | 5/18 | **9/18 (0.50)** |
| top3 | 0.6 | 8/18 | **11/18 (0.61)** |
| top10 | 0.8 | 12/18 | **15/18 (0.83)** |
| noMatchCorrect | 1.0 | 6/6 | 6/6 |
| confidenceCompliant | 1.0 | 28/29 | **29/29** |

- **Margins are thin.** top3 and top10 each pass by a single case.
- **Exit status:** the gates are XCTest assertions. Both the baseline run on `dff58fd`
  and an intermediate run of this fix (top1 7/18) exited 1, naming each failed gate.
- **Other variants** (not gated):
  - Global + Caribbean 8: recall 33/34, top1 18/34, top3 24/34, top10 30/34,
    confidence 46/46. Before: 32, 13, 17, 26 and 44/46.
  - The `v05-ambiguous-angelfish` violation came from the one-word "Angelfish"
    record and is fixed by the same rule.
  - Release-approved Global: 0 records, all 46 cases out of scope.
- **Regional packs (`run_v05.py`): every gate passes.** Production top1 is 26/34
  (was 27/34), top3 33/34 and top10 34/34; confidence is 46/46.
  - The one change is `v05-01-paraphrase`, where Atlantic Blue Tang drops from #1 to
    #2 (bound 10). Its juvenile variant repeated the main profile's yellow and "tail"
    marking, so before, any mention of a tail scored that evidence twice.

### Per case (rank of the expected species in the displayed ten)

| Case | Before | After | Remaining failure |
| --- | --- | --- | --- |
| 09-diagnostic, Bird wrasse | — | — | ranking: retrieved #2, but FishBase gives no colour, so 10 green or solitary reef fish outscore it |
| 09-paraphrase, Bird wrasse | — | — | ranking: retrieved #21; "pointed nose" does not match "long snout" |
| 10-diagnostic, Black triggerfish | 3 | **1** | |
| 10-paraphrase, Black triggerfish | — | — | retrieval: not in the top 50; "pale blue borders at the fin bases" has no source |
| 11-diagnostic, Pinktail triggerfish | 2 | **1** | |
| 11-paraphrase | 1 | 1 | |
| 12-diagnostic, Red-toothed triggerfish | 8 | **1** | |
| 12-paraphrase | 1 | 1 | |
| 13-diagnostic, Orangespot surgeonfish | 10 | **2** | |
| 13-paraphrase | 6 | **5** | top3: ties at raw 25–28 with other oval orange reef fish |
| 14-diagnostic, Lined surgeonfish | — | **1** | |
| 14-paraphrase | 9 | **1** | |
| 15-diagnostic, Fire clownfish | 2 | 4 | top3: eight anemonefish tie at raw 14. It was #2 only because "red-orange anemonefish" named the Orange anemonefish |
| 15-paraphrase | 1 | 4 | top3: ties at raw 20. Its juvenile "stripes" no longer repeat the main profile's |
| 16-diagnostic, Spinecheek anemonefish | — | **7** | top3: FishBase gives no white bars |
| 16-paraphrase | 1 | 1 | |
| 17-diagnostic, Cockatoo waspfish | 1 | 1 | |
| 17-paraphrase | — | **2** | was a retrieval failure; "leaflike" now also matches its "Leaf fish" name |
| ambiguous-trigger (ceiling 0.64) | 0.643 | **0.190** | |

**Cases still outside a gate's rank, by cause.** Retrieval: 1 (10-paraphrase).
Ranking: 2 outside the top ten (09-diagnostic, 09-paraphrase) and 4 between #4 and #7
(13-paraphrase, 15-diagnostic, 15-paraphrase, 16-diagnostic). Each remaining cause is
a clue with no source or a tie among close relatives; neither is fixed by weights.

### Golden ordering

`SearchGoldenOrderingTests` now compares against `SearchGolden.v2.json`, regenerated
for this approved change. The query set (137 × 5 packs) is unchanged. The v1 → v2
differences:

| Pack | Ranked order changed | Top result changed | Retrieved pool order changed |
| --- | --- | --- | --- |
| Caribbean (development, 8) | 15 | 5 | 0 |
| Caribbean (Release, 2) | 6 | 6 | 0 |
| Tropical Pacific | 9 | 0 | 28 |
| Global | 89 | 53 | 115 |
| Global batch 1 (250) | 84 | 37 | 113 |

- **Caribbean:** every change is the variant de-duplication. The two Release records
  no longer place Atlantic Blue Tang first for ray descriptions that mention a tail.
- **Tropical Pacific:** the pool changes come from the "-like" stem and the new
  relationships in BM25 terms.
- **Global:** includes the builder v4 content.

## Caribbean species in Global (2026-10-23)

Global is rebuilt from the pinned FishBase/SeaLifeBase release v26.06. All 34 tables
matched their pinned size and MD5, and the rebuilt drafts are identical to the committed
ones.

**Every pack keeps the v3 field-guide text for its regional species** (owner decisions,
2026-10-23):
- **Caribbean and Tropical Pacific** stay as they are.
- **Global** now holds the 8 Caribbean species as the Caribbean pack's own records,
  appended after the 4,786 FishBase records, for 4,794 in total.
- **Differences in Global:** each copy is a draft there (a regional approval does not
  carry over; Global approval comes only from a recorded batch decision) and has no
  bundled image.

**Why not FishBase text.** Rebuilding these species from FishBase was tried first and
rejected; the field-guide clues divers describe are not in FishBase:
- **Tropical Pacific pack:** it broke three case rank limits: v05-09 diagnostic and
  paraphrase (Bird wrasse) and v05-10 paraphrase (Black triggerfish).
- **Release:** it would have exposed no record, because the rebuilt Atlantic Blue Tang
  and Queen Angelfish no longer matched their approved content.
- **Global:** with FishBase text for the 8 Caribbean species, the Global gate fell to
  recall 23/34, top1 12/34, top3 15/34 and top10 21/34.

**Regional search is unchanged.** All 184 `run_v05.py` case results are identical
before and after: ranks, failures and displayed species, development and Release. In
`SearchGolden.v2.json`, only the 137 `global` results changed. The one regional entry
that differs is the excluded parser-order query ("a school of spotted rays crossed the
sandy channel"), whose ranked score varies between processes; its pool is identical.

**The opt-in Global gate passes on all 34 positive cases.** The 16 Caribbean
identification cases are no longer blocked by coverage:

| Global (4,794 records) | Recall | top1 | top3 | top10 | No-match | Confidence |
| --- | --- | --- | --- | --- | --- | --- |
| As written | 33/34 | 18/34 | 24/34 | 30/34 | 6/6 | 46/46 |
| Before (Tropical Pacific cases only) | 17/18 | 9/18 | 11/18 | 15/18 | 6/6 | 29/29 |
| Tropical Pacific records only (diagnostic, unchanged) | 17/18 | 11/18 | 15/18 | 16/18 | 6/6 | 29/29 |

Release still exposes the 2 approved Caribbean records through the Caribbean pack only;
Global has no approved record.

## Performance (host measurements, Release)

| Pack | Records | Load (median) | Document build | BM25 retrieval (median) | Query median | Query p95 | First query | RSS after queries (peak) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Caribbean | 8 | 2.2 ms | 1.1 ms | 6.0 ms | 17.5 ms | 25.3 ms | 24 ms | 30 MiB (30) |
| Tropical Pacific | 1,000 | 68 ms | 136 ms | 658 ms | 753 ms | 1,033 ms | 1,031 ms | 44 MiB (44) |
| **Global** | 4,786 | **845 ms** | 1,043 ms | **5,678 ms** | **5,542 ms** | **6,567 ms** | **6,924 ms** | **117 MiB (132)** |

- **Sample counts:** 138 queries per pack (46 × 3), with 0 failures. Process start
  was 26 MiB.
- **Release `availablePacks()` (publication access)** now takes **942 ms** median
  (p95 1,066 ms). It still decodes and validates all three packs, including the
  hidden 13 MB Global pack. Before this change Global was empty; the loads of the
  other two packs suggest about 70 ms then.
- **Debug:** the Global evaluation took the same wall time in Debug and Release
  (~460 s for 104 searches, including loads). The cost is in work that is already
  optimised in both.

**Causes:**

1. **BM25 retrieval re-tokenises every document on every query.** This is linear in
   pack size and accounts for over 95% of query time. It already costs 0.75 s on
   Tropical Pacific.
2. **The search-document cache hashes every profile on every query** to build its key:
   31 ms at Global size.
3. **Loading decodes and validates 13 MB of JSON,** and publication access does the
   same just to list packs.

### After the BM25 index and manifest-only listing (2026-10-22, finding P2)

**Host measurements** (Linux container, Release, 4 cores, Swift 6.1), not iPhone
numbers. Raw figures: `Reports/GlobalPackPerformance.release.json`.

**What changed:**
- **BM25 index:** per-document term frequencies, lengths, the average length,
  document frequencies and normalized names are built once per catalogue content.
  The index is cached with the search documents and keyed by the pack's ID, version,
  record count and a content fingerprint computed once when the pack is built.
  Changed content gets a new entry.
- **Cache key:** the search cache no longer hashes every profile on each query.
- **Listing:** `availablePacks()` reads manifests only.

| Pack | Records | Index build (once) | First query | BM25 retrieval (median) | Query median | Query p95 | RSS after queries (peak) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Caribbean | 8 | 5 ms | 33 ms | 0.3 ms | 12.5 ms (was 17.5) | 21 ms (was 25) | 31 MiB (31) |
| Tropical Pacific | 1,000 | 724 ms | 803 ms | 2.2 ms | 39 ms (was 753) | 47 ms (was 1,033) | 49 MiB (49) |
| **Global** | 4,786 | 4,837 ms | **5,869 ms** (was 6,924) | 11.7 ms | **103 ms (was 5,542)** | **153 ms (was 6,567)** | 154 MiB (was 117) |
| Global batch-1 subset (Release-sized) | 250 | 393 ms | 494 ms | 0.6 ms | 81 ms | 123 ms | see note |

- **Listing:** `availablePacks()` takes **0.35 ms** with Release access (was 942 ms)
  and 0.32 ms with development access. Each sample uses a fresh repository.
- **Samples:** 138 queries per pack (46 × 3), with 0 failures. Index build is 3
  samples, retrieval 46.
- **Memory:** VmRSS and VmHWM are cumulative in one process. The Global index adds
  about 35 MiB resident. The subset row follows five more full Global loads, so its
  memory figures are not comparable.
- **Release subset:** Release currently exposes no Global records, because the
  batch-01 approvals lapsed. The 250-record row is batch 1's records taken from
  development content.

**Ordering is identical.** `SearchGoldenOrderingTests` compares 685 query results
(137 development queries × 5 packs) against outputs captured on `a687477` before the
change: exact ranks and every score to 1e-9. A mutation of the index (document
lengths + 1) fails 27,252 assertions.
- **Exception, from a pre-existing issue:** one query, "a school of spotted rays
  crossed the sandy channel", has its ranked scores excluded; its retrieved pool is
  still compared. On `main` too, `LocalObservationParser` applies synonyms in hash
  order, so "sandy" → "sand" → "bottom-swimming" happens in some processes and not
  others. Fixing this would change that query's ranking, so it is left for an owner
  decision.

**Remaining cost:**
- **First query on a pack's content** builds its index (Global 4.8 s on the host).
  It is not persisted to disk.
- **Warm queries:** about 80–100 ms of each warm Global query is ranking the 50
  retrieved candidates. The ranker matches morphology patterns against each
  candidate's fin and head clues on every query, and Global records carry many.

### Cold index loading (2026-10-22)

**Profile first.** Global first search, Linux host, Release, after the builder v4
ranking change:

| Step | Cost |
| --- | --- |
| Catalogue decode and validation | 1.54 s |
| Pack construction (fingerprint, group names) | 0.41 s |
| Search documents | 1.12 s |
| BM25 index build | 6.47 s |
| Search once built | 21 ms |

Inside the index build:
- **`normalize`:** 1.4 s, three regex replacements per call.
- **Morphology `scopedText`:** 1.9 s; it compiled four patterns on every call.
- **Appearance relationships:** 1.7 s.
- **Re-tokenising every name:** 2.3 s, through the same per-call compilation.

**What changed:**
1. **Cheaper tokenisation, same output.**
   - Regexes are compiled once (morphology, negated phrases).
   - `normalize` is one pass over bytes, with the earlier Unicode path kept for the two
     characters whose lowercase is ASCII and for non-ASCII whitespace at either end.
   - `SearchIndexStoreTests` checks `normalize` against the old regex implementation,
     and the golden test checks every result.
2. **`SearchIndexStore`** replaces the in-memory document cache.
   - **One build per catalogue content,** run outside the store's actor and off the
     main thread; concurrent requests share it.
   - **Cancellation:** a cancelled request returns at once, and the build carries on
     for the next one.
3. **Background preparation.** Opening the Describe screen starts loading or building
   the selected pack's index (`SearchIndexPreparation`) at utility priority. It is not
   started at app launch, and nothing waits for it.
4. **A validated persisted index** in the app's Caches directory, written after the
   index is returned so no search waits for the disk. It is used only when:
   - its header matches the format, document schema, a tokenizer probe, the app
     version and build, the document builder, and the pack ID, version and record count;
   - it matches the pack's stable content key: an FNV-1a digest of the species
     resource, plus whether it was the development or Release-filtered set;
   - its checksum is intact;
   - its records are exactly the pack's records;
   - sampled entries rebuilt from their profiles are identical.

   Anything else is deleted and rebuilt. Other archives for the same pack are removed
   when a new one is written. The SwiftPM build never persists, so tests and
   evaluations do not touch user caches unless they pass a directory.

**Host timings** (Linux container, Release, 4 cores; `GlobalPackPerformanceTests`,
`Reports/GlobalPackPerformance.release.json`). Each launch is a fresh repository and
index store in the same process, so the file cache is warm. **These are not iPhone
numbers.**

| Pack | Fresh install: launch to search-ready | Later launch (stored index) | First query once ready | Warm query median (p95) | Stored index |
| --- | --- | --- | --- | --- | --- |
| Global (4,786) | 4.93 s (was 9.6 s) | **0.89 s** | 63 ms | 54 ms (87 ms) (was 119 ms) | 2.99 MB |
| Tropical Pacific (1,000) | 704 ms | 141 ms | 32 ms | 33 ms | 0.46 MB |
| Caribbean (8) | 7.5 ms | 4.6 ms | 7.0 ms | 6.3 ms | 6.6 kB |

- **"Was" figures** come from the same test on the builder v4 code, before this
  change: 1.30 s decode, 1.19 s documents, 7.16 s index, and a 119 ms warm median.
  The earlier 4.8 s index (5.9 s first query) predates the new relationship patterns.
- **Readiness** is pack decode plus index load or build. The Global later launch is
  about 0.74 s of decoding plus 0.15 s of reading the stored index.
- **Index build** (Global) is 3.15 s, down from 6.47 s. Appearance relationships
  (1.35 s) are now its largest part.
- **With preparation,** the first search waits only for whatever part of readiness is
  still running when it is submitted.
- **Memory:** the Global index is held once per content. The resident figures in the
  report are cumulative for one test process.

## Options (none applied; owner decision needed)

**Quality**

1. **Write diver-facing descriptions** for Global records (appearance and behaviour,
   original wording) through the review pipeline, starting with the 962 Tropical
   Pacific species. This is the only option that addresses the cause; it is content
   work.
2. **Carry each retired regional record's original-wording visual clues** (body
   shape, behaviour, markings) into the matching Global record as reviewed fields.
   This is faster but partial, and the field-guide wording itself was removed on
   licence grounds.
3. **Keep the regional packs as the default search scope** until Global's text meets
   the gates. Global stays an opt-in Debug pack. This is the current state.
4. **Ranking retune** (for example a wider retrieval pool, or BM25 field weights):
   needs your approval and cannot replace the missing text.

**Location boundary**

5. **Apply the −3 penalty only within the displayed window,** so a species is never
   pushed out of it, or exempt candidates that are already displayed. Either is a
   ranking change and needs your approval.
6. **Accept that a marginal species can leave the top 10** and document it.

**Performance**

7. **Pre-tokenise documents once per pack** and cache the BM25 index (term
   frequencies, document lengths) alongside the documents. Results stay identical.
   This is expected to bring retrieval to tens of milliseconds.
8. **Key the document cache by pack id and version,** plus a content fingerprint
   computed once at load, instead of hashing profiles per query.
9. **Read manifests only** for `availablePacks()`, and skip loading packs that
   publication access would hide.
10. **Defer Global loading to first use** and keep it off the launch path.

Options 7–9 change no results and could be done before any quality work; they are
proposed, not implemented.
