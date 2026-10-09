# Tropical Pacific description-search correction

## Scope and baseline

Pass executed 2026-10-09 on clean branch `work`, starting at `f7694dd`
(main's merge of PR #79; that PR enables the DEBUG compilation condition).
No applicable AGENTS.md was present. Tests use the 384-record draft Pacific
pack, production BM25 retrieval with 50 candidates, biological ranking, and
10 displayed results. No algorithm, weights, candidate limits, publication
policy, positive rank bounds, expected IDs, or no-match assertions changed.

The full baseline Pacific suite reproduced the single positive failure.

| Fixture case | Before displayed | After displayed | Required maximum |
| --- | ---: | ---: | ---: |
| Ribbontail Ray | 1 | 1 | 3 |
| Dragon Moray | 1 | 1 | 3 |
| Fire Dartfish | 5 | 5 | 5 |
| Cockatoo Waspfish | absent | 1 | 5 |
| Blackspotted Puffer, short | 6 | 6 | 10 |
| Bluespotted Ray, short | 1 | 1 | 5 |
| Freshwater frog | no match | no match | no match |

## Retrieval and biological trace

The waspfish query parses category `fish`, color `brown`, and behavior
`bottom-swimming`; no structured shape, habitat, or marking is recognized.
Before correction its BM25 rank is 81, score 4.693223201117945, matched terms
`bottom`, `dorsal`, `fish`. It misses the 50-candidate boundary entirely.
Isolated ranking (diagnosis only) finds it eligible at raw score 6 for `fish`,
with no conflicts. This establishes a retrieval miss rather than rejection.

After the source correction its BM25 rank is 3, score 18.01633610114738,
matched terms `bottom`, `brown`, `debri`, `dorsal`, `fin`, `fish`, `like`,
`sail`. It enters the production pool and is biologically eligible at raw
score 11: fish (6), brown (3), fin/spine clue (2), with no conflicts. It
ranks first both in the hybrid output and in the service's displayed results.
The parser still does not recognize leaf shape or swaying; neither is falsely
encoded as bottom-swimming to earn behavior points. No remaining failure
justifies a general retrieval or ranking change.

Fire Dartfish retrieves at rank 1 before and after (BM25 score
15.37792039201181 → 15.373917616366668), raw biological score 15, displayed
rank 5. Small corpus-wide BM25 score changes are expected from document
length/frequency changes.

## Inspected evidence and durable correction

The workbook's waspfish source `SRC-B853F73C` identifies book p. 381
(PDF p. 382), *Reef Fish Identification: Tropical Pacific*. Its high-confidence
trait `TRT-D7180089` is only a comparison with Spiny Waspfish plus spine count,
social behavior and habitat. The other identification trait has low-confidence
corrupted OCR. Neither supports inheriting the preceding species' appearance.
The original scan remains unavailable in the repository.

Accessible authoritative accounts were inspected through the web tool:

- [Bray, D.J. 2023, Fishes of Australia, Ablabys taenianotus](https://fishesofaustralia.net.au/home/species/3205),
  Summary and Features, accessed 2026-10-09: variable coloration including
  brown, reddish, yellowish and white areas; strong lateral compression;
  elevated anterior dorsal spines; swaying that imitates leaves/debris in surge.
  The text is CC BY 3.0 Australia; no photographs were imported.
- [McGrouther, Australian Museum, Cockatoo Waspfish](https://australian.museum/learn/animals/fishes/cockatoo-waspfish-ablabys-taenianotus-cuvier-1829/),
  Identification, updated 6 May 2022, accessed 2026-10-09: brown coloration
  and a sail-like dorsal fin beginning above the eyes. Only a short trait
  label is stored from this account, with attribution.

The fixture's previous URL `/home/species/2118` actually identifies
*Scorpaenodes hirsutus* (Hairy Scorpionfish). Only that source URL was corrected
to `/home/species/3205`; the fixture description and all assertions are intact.

`Data/CatalogReview/ReviewDecisions.json` adds a fingerprint-bound **draft**
overlay for stable species ID `5f4d48f4-6556-50f3-95af-a4d28635f4bb`.
It supplies controlled colors, compressed body shape, the dorsal-fin clue,
and a separately written feature summary. It retains the original workbook
summary, feature, source ID and locator, appending field-scoped source records
`FOA-3205` and `AM-ABLABYS-TAENIANOTUS`. It does not copy the test sentence.
The existing importer regenerates the catalogue and reports the decision as
applied. Reimport is byte-identical across all five generated outputs.

No human reviewer or review date is fabricated. All 384 records remain draft;
human-reviewed and publication-eligible counts remain zero. Original source-page
and independent taxonomy review remain outstanding for publication.

## Verification

- Baseline full Pacific suite: 15 tests, one failure (waspfish positive).
- Corrected full SwiftPM suite: 79 tests, zero failures, one intentionally
  skipped opt-in frozen evaluation. All seven Pacific fixture cases pass.
- Caribbean development quality gates pass for both structured and hybrid
  engines; limited-description confidence/no-match checks also pass.
- The explicit frozen Caribbean 100-case evaluation was run separately with
  `DIVEID_FROZEN_HOLDOUT=1`: passed for both engines (one test, zero failures).
- Python importer: 6 tests passed; catalogue review: 16 tests passed.
- Diagnostic regression now checks candidate-pool inclusion, isolated biological
  eligibility/support, and displayed rank separately. The independent
  no-retrieved-candidates versus all-candidates-rejected test is retained.
- Xcode/iOS Simulator and device checks are unavailable in this Linux pass.

Commands use Swift 6.2.3 with writable `CLANG_MODULE_CACHE_PATH` and SwiftPM
`--cache-path` under `/workspace/.dive-id-toolchain`. The initial invocation
without those paths failed before testing due to a read-only home cache.
