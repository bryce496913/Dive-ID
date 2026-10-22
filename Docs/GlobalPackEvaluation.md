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
as written, so **it now fails** when it runs. It is still opt-in, through
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

## Performance (host proxy, Release)

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
