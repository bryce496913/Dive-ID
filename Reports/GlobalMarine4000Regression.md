# Global marine processing: achieved state and quality evidence

Baseline: main `d6bb2667f027cf6cee63ebdae3c5cd83df4d58b1`, tree
`024dd6db75a9c66a1f4e7a4f00f77f1886fa990d`. Intake implementation published as
`d586b97d893f6bbeab8fb938f58cd167f8ec834d` (PR #104). The containing evidence commit
identifies this record's code; `GlobalMarine4000Reproducibility.json` pins all output
and protected-resource hashes. Source snapshots are pinned by the original audit's
Git blob SHAs, which intake independently verifies. Candidate/reserve/source hashes
are in `GlobalMarine4000Intake.json`.

## Actual counts

| Gate | Achieved |
| --- | ---: |
| Primary candidates validated | 4,000 |
| Separate reserve candidates | 529 |
| Completed offline 250-row checkpoints | 16 |
| Exact source-CSV name matches | 3,994 |
| Turtle overview entries requiring species accounts | 6 |
| Verified existing workbook UUID links preserved | 307 |
| Provisional new candidate UUIDs | 3,693 |
| WoRMS REST-confirmed primary taxa | 0 |
| Primary records still taxonomically unresolved | 4,000 |
| Canonical accepted taxa emitted | 0 |
| Records with inspected partial field evidence | 2 |
| Evidence-complete draft profiles emitted | 0 |
| Regional-export-eligible profiles | 0 |
| New exact-content human-verified/publication-eligible profiles | 0 |
| Existing publication-eligible profiles (unchanged) | 2 |

Empty canonical/profile outputs are intentional. Neither 4,000 rows nor successful
mock HTTP tests are taxonomic confirmation. All 529 reserves remain unused; no
accepted-taxon collision has yet been established. Names are compared against all
1,650 workbook rows, both packs and the 616 supplement. One workbook identity
`42fa741c-5d6f-5be2-bd62-5e0d9e0f6366` has no readable scientific name; preserve its
UUID and resolve that source identity before claiming complete collision clearance.
The baseline has 1,649 distinct readable scientific-name inputs.

The owner's exact statement, “All of the 4000 are approved by me”, is retained in
`CandidateApprovalContext.json`. It approves the supplied candidate set; subsequent
researched content, fingerprints and regional claims did not exist at that point.
No biological facts or future exact-content review decisions are manufactured.

## Inspected evidence

- `MARINE5K-00001`, Achoerodus gouldii: Fishes of Australia species 206 and FishBase's
  species account support name, wrasse category, morphology, habitat, life-stage
  appearance and a 175 cm maximum **total length**. Temperate southern Australian
  distribution does not justify either current pack. FishBase's 5–65 m depth and
  Fishes of Australia's reported maximum 100 m remain conflicting field evidence.
- `MARINE5K-03673`, Eretmochelys imbricata: NOAA's species account supports shell/head
  appearance, habitats, life stages and specific Caribbean/Hawaiian nesting
  occurrences. Quick Facts gives 2–3.5 ft length; Appearance gives up to 2–3 ft shell
  length. The unresolved size/type discrepancy is retained rather than exported.

`EnrichmentEvidence.jsonl` contains 21 field entries, exact URLs/sections, access
dates, original summaries and evidence fingerprints. `EnrichmentStaging.json`
retains conflicts and missing fields. These are automated source inspections, not
human biological review. No imagery was imported. Category changes are deferred:
59 input candidates require schema review and remain pending; no echinoderm was
reclassified as fish/mollusk.

## Executed validation

- Complete Python suites: **133 tests passed**, including 35 global intake,
  HTTP-cache, evidence, identity, reserve and comparison tests. CI now discovers
  this suite independently of Swift. Synthetic API IDs stay confined to tests.
- Swift 6.2.3 on Linux: Debug and optimized Release each executed **129 tests,
  3 skipped, 4 failed assertions across 3 test methods**, exactly the known baseline
  search failure areas. Exact bundled publication-set checks passed in both.
- Complete unchanged frozen 46-case evaluation run before and after. The comparison
  reports **zero additional regressions**. Case sets, fixture hash, actual engine,
  coverage, recall, ranks, confidence and abstention metrics are checked. Existing
  failure assertions remain mandatory; this comparison does not turn them green.
- Two complete offline replay passes: all 26 generated artifacts byte-identical;
  119 protected app/fixture/review files unchanged. Existing catalogue regeneration
  also passed twice. `git diff --check` passed.

Production BM25 development metrics are unchanged: recall 33/34, top-1 27/34,
top-3 32/34, top-10 33/34, no-match 6/6, region conflicts 4/4, ambiguity 2/2.
Publication coverage remains 10 applicable cases / 36 blocked, positive recall 4/4,
top-1 3/4, top-3/top-10 4/4; no-match 3/3, conflicts 2/2, ambiguity 1/1.

Remaining baseline failures: Fire Dartfish displayed rank 6 against maximum 5
(and its historical diagnostic expects 5); `v05-14-paraphrase` misses the BM25
50-candidate boundary and the full-pack structured comparator's displayed-rank
requirement. No ranking changes, raised limits, species boosts or fixture edits.
Complete before/after reports and test diagnostic excerpts are in
`Reports/GlobalMarine4000Quality/`.

## Blockers and next execution

WoRMS REST was unavailable: enforced executor host policy omits
`www.marinespecies.org`; executor proxy connection failed; browser REST fetch also
failed. Webservice documentation and the cited biological pages were accessible
through browsing. Supply authorized working REST access or genuine URL-addressed
response snapshots, then resume the same 250-row checkpoints, resolve seven
baseline-name batches and use reserves only for confirmed collisions. No REST
response or AphiaID was invented. Complete species-specific source inspection for
the remaining 3,998 records, resolve the two evidence conflicts and review exact
assembled content before publication. A named approval cannot supply missing facts.

Xcode/iOS simulator/device checks and device latency/memory measurements remain
unexecuted: this environment is Linux without Apple hardware. No global staging
records are loaded by the app, so these runs cannot establish performance at 5,000
searchable profiles. Independent diver-description submissions remain absent; no
real-world accuracy claim is made.

## Reproduction commands

From the repository root, with Swift 6.2.3 on PATH and the declared Python
requirements installed (this environment used `/workspace/.dive-id-venv/bin/python`):

```sh
python3 Tools/Evaluation/run_v05.py --output /tmp/global-before.json --log /tmp/global-before.log
# Preserve the nonzero exit above; it records existing gate failures.
python3 Tools/GlobalMarineImport/intake.py
for batch in $(seq 1 16); do
  python3 Tools/GlobalMarineImport/process.py --batch "$batch" --resume --offline-cache-only
done
python3 Tools/GlobalMarineImport/enrichment.py
python3 Tools/GlobalMarineImport/verify_reproducibility.py
python3 Tools/CatalogReview/verify_source_review_reproducibility.py
DIVEID_V05_REPORT=/tmp/global-after.json swift test --jobs 4
swift test -c release --jobs 4
python3 Tools/GlobalMarineImport/compare_quality.py /tmp/global-before.json /tmp/global-after.json
# Run independently so an earlier failure never suppresses later suite evidence:
failed=0
for suite in CI CatalogImport CatalogReview GlobalMarineImport Evaluation TropicalPacificWorkbook SemanticSearch/tests; do
  python3 -m unittest discover -s "Tools/$suite" -p 'test_*.py' || failed=1
done
test "$failed" = 0
git diff --check
```

CI evidence for intake commit `d586b97d893f6bbeab8fb938f58cd167f8ec834d`:
https://github.com/bryce496913/Dive-ID/actions/runs/38827623193 . At inspection,
all seven Python jobs passed, Linux and macOS SwiftPM jobs failed, and hosted Xcode
was still running. Hosted completion is not claimed; local search-failure traces
above are separate evidence from these CI statuses.
