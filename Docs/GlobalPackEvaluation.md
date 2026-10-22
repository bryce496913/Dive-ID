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

| Case | Species | Out-of-range clue | Rank without | Rank with |
| --- | --- | --- | --- | --- |
| clown-triggerfish-caribbean | *Balistoides conspicillum* | Caribbean | 10 | **not returned** |
| clown-anemonefish-belize | *Amphiprion ocellaris* | Belize | 3 | 4 |
| regal-angelfish-bonaire | *Pygoplites diacanthus* | Bonaire | 3 | 7 |
| queen-triggerfish-fiji | *Balistes vetula* | Fiji | 2 | 5 |
| moorish-idol-florida | *Zanclus cornutus* | Florida | not returned | not returned |
| spanish-hogfish-hawaii | *Bodianus rufus* | Hawaii | not returned | not returned |

- **Where the species is returned with an out-of-range clue,** eligibility score and
  confidence are unchanged and ordering is lower, as designed.
- **The engine returns at most 10 results.** A species at rank 10 drops out entirely
  under the −3 penalty, so "never a filter" does not hold for marginal matches.
- **Two cases are invalid at present.** The Moorish idol and Spanish hogfish are not
  returned even without a location: the same text cause as above.
- The test asserts the requirement, so **it fails today (3 of 6 cases)**.

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
