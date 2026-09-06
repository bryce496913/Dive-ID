# Candidate Retrieval and Identification Quality Gate

## Scope and evaluation modes

The version 1 gate evaluates an explicitly constructed `StructuredDescriptionSearchEngine`
and `HybridDescriptionSearchEngine(BM25, limit: 50)` through
`LocalMarineLifeIdentificationService.identify`, the same service boundary used by the
application. A capture adapter records the **same** `DescriptionSearchResult` consumed by
the service, so score diagnostics cannot silently come from a second ranker run.
Production still defaults to the hybrid engine; this benchmark does not change that default
or integrate a model.

Routine runs use only the 70-case `development` split. The original 100-case
`CaribbeanIdentificationBenchmark.json` is unchanged (70 development, 30 holdout).
Set `DIVEID_FROZEN_HOLDOUT=1` to opt into the frozen full-fixture evaluation. Reports from
that mode omit descriptions, so routine development and failure logs do not expose holdout
wording. Holdout observations must not be used for training, search-document generation,
prompt rules, or ranking tuning.

A separate `CaribbeanLimitedDescriptions.v1.json` development fixture covers sparse useful
observations, an ambiguous observation with multiple catalogue-supported acceptable matches,
and adjacent insufficient observations that must abstain. It is versioned separately so it
cannot alter the original fixture's membership or historical denominator.

## Metric contract and denominators

For each positive case, the accepted set is the union of `expectedSpeciesIDs` (the primary
ground truth) and `acceptableSpeciesIDs` (alternate outcomes explicitly supported by the
catalogue). `primaryExpectedRank` reports rank against only the primary set;
`acceptedRank`, top-1/top-3/top-10, expected-rank outcomes, and candidate recall use the
union. Thus acceptable alternatives can satisfy quality metrics without hiding where the
primary answer ranked.

Top-k denominators are **positive cases only**: 56 development or 80 frozen. Correct
no-match rate is correct empty results divided by expected-no-match cases: 14 development
or 20 frozen. `falsePositives` counts no-match cases that returned one or more results.
Candidate recall is positive cases whose accepted set intersects the pre-ranking retrieval
pool, divided by all positive cases. It is reported independently of final rank and at the
engine's configured limit (50 for hybrid; the complete eight-profile pack for structured).
Metrics are also grouped by split and declared fixture information level.

Every case reports ID, split, expected-rank contract, outcome, primary and accepted rank,
candidate recall/limit, returned top confidence and information level, and up to ten actual
engine candidates. Candidate diagnostics include raw structured score, normalized retrieval
relevance, combined ordering score, display score, matched/conflicting evidence, and
information level. Descriptions are suppressed in frozen holdout mode.

`expectedRank` is a closed enum: `top1`, `top3`, `top10`, and `none`. `none` must accompany
an expected no-match and an empty primary set; positive ranks require primary IDs. Decoding
rejects unknown values such as `top5` rather than accidentally treating them as top-3.

## Version 1 acceptance thresholds

| Cohort / engine | Top 1 | Top 3 | Top 10 | Correct no-match | False positives | Candidate recall |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Development, structured | 38/56 | 42/56 | 45/56 | 14/14 | 0 | >= 80% |
| Development, hybrid BM25-50 | 43/56 | 44/56 | 45/56 | 14/14 | 0 | >= 80% |
| Frozen aggregate, structured | 44/80 | 59/80 | 64/80 | 20/20 | 0 | >= 80% |
| Frozen aggregate, hybrid BM25-50 | >=44/80 | >=59/80 | >=64/80 | 20/20 | 0 | >= 80% |

The structured floors exactly reproduce the historical measurement before establishing the
gate: 44/80 top-1, 59/80 top-3, 64/80 top-10, and 20/20 no-match. They are regression
floors, **not production-quality claims**. The development floors are the measured split
contribution to that baseline. Hybrid development gets its own measured floors because the
real service-path run is 43/56, 44/56, and 45/56; the old report's identical hybrid numbers
came from diagnosing a separate structured-ranker invocation. The corrected frozen hybrid
measurement is 51/80, 63/80, 64/80, with 20/20 no-match. Its frozen minimum deliberately
retains the version-1 aggregate floor while the stricter measured development floor catches
routine regressions.

No-match is exact and false positives must remain zero because returning a species for a
curated no-signal observation is a safety behavior regression, not a ranking tradeoff.
Candidate recall starts at 80% to make pre-ranking loss independently visible while allowing
future larger packs to expose a bounded-retrieval limitation; the current eight-species pack
measures 80/80 for both engines. All required positive, no-match, split, and information-level
cohorts must be nonempty.

The limited fixture applies strict per-case behavior rather than an aggregate average:
useful limited cases must meet their declared rank, ambiguous cases may use only their listed
acceptable IDs, insufficient cases must return nothing, and every limited result must remain
`.limited` with confidence at most `0.64`. A controlled semantic retriever returning cosine
similarity 1.0 verifies similarity cannot upgrade that confidence. A deliberately empty
engine is also evaluated and the test asserts the threshold validator rejects its report,
proving the gate is capable of failing.

Thresholds are numeric and versioned in `BenchmarkThresholds.version`. Raising them requires
a measured engine improvement. They must not be lowered, and cases must not be relabelled,
removed, or moved between splits to conceal a regression. If an engine misses a future gate,
the failing IDs remain in the assertion/report for the subsequent ranking pass.

## Commands

```bash
# Routine development gate (holdout test is explicitly skipped)
swift test --filter IdentificationBenchmarkTests

# Frozen full-fixture evaluation; report does not include holdout descriptions
DIVEID_FROZEN_HOLDOUT=1 swift test \
  --filter IdentificationBenchmarkTests.testExplicitFrozenHoldoutEvaluationMode

# All relevant search and benchmark suites
swift test
```
