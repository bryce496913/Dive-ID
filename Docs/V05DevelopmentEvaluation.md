# v0.5 development evaluation

This pass adds evaluation only. The prerequisite spine-vocabulary correction is
isolated in PR #85 (`92a975e`), whose complete Debug and Release suites passed
107 tests with one opt-in frozen evaluation skipped. The evaluation branch adds
no parser, ranker, retriever, catalogue or publication-status changes. Existing
Caribbean/Pacific fixtures and thresholds remain unchanged.

## Frozen inputs and provenance

The suite has 46 AI-authored synthetic descriptions: 34 positive descriptions of
17 species, two ambiguous observations with explicit acceptable alternatives,
six abstention cases and four regional conflicts. It covers all eight Caribbean
starter identities and nine Pacific identities, including eight not represented
in the existing Pacific positive fixture. Diagnostic descriptions and paraphrases
include metric/imperial length and depth, short accounts, life stages, and confusing
triggerfish, angelfish and anemonefish alternatives. It is bounded development
coverage, not a representative sample of the 392-record catalogue.

Each positive case links to an evidence entry with a stable ID, scientific name,
source URLs/book-page references, supporting facts, and a pre-run rank requirement.
Authoritative accounts were inspected; some Pacific color traits additionally rely
on the existing high-confidence book transcription. Original book pages were not
independently inspected. Sources support identity/traits, not rank requirements.
No source inspection, fixture identity or test result grants publication approval.
Descriptions are not collected diver data, independent human review, or a holdout.
The existing frozen benchmark cohort was not opened or tuned here.

Original cases, thresholds and collection protocol were committed remotely **before
execution** at `1481b619598c40b63cebbb89985e92064507567e`. Version 1 had an ID-lookup
construction error: the Pacific Spotted Eagle Ray overwrote the intended Caribbean
record because both share a common name. Version 2 corrects only that evidence
mapping and the selected pack/expected ID of two cases, using the already cited
western Atlantic account. Descriptions, rank bounds and thresholds did not change.
The original v1 fixture, protocol and result report are retained for audit.
Version 2 was committed before rerun at `5a9dbf3d455d16274ac3b73a77b165e1db7ca9c0`.
V2 has seen v1 results and must not be represented as unseen evaluation data.
A contract test checks the precise erratum and preserves all descriptions/bounds.

`Data/Evaluation/V05Protocol.v2.json` freezes a SHA-256 of the fixture plus floors:
85% candidate recall; 40%/60%/80% top-1/3/10; 100% explicit no-match, regional
conflict and confidence-contract compliance. These provisional development floors
were chosen before results to require a majority of targets near the top and broad
coverage inside the UI's ten results, while allowing difficult draft-pack cases.
They are not publication acceptance criteria. Every diagnostic case also requires
top-3 and every paraphrase/ambiguous case top-10. Missing a case requirement fails
even when an aggregate passes. No floor was lowered after observing output.

## Service path and denominators

`V05DevelopmentEvaluationTests` calls `LocalMarineLifeIdentificationService.identify`
with a real bundle-only repository, alternating experimental-development and
publication access. An observing wrapper captures the engine's retrieval pool and
analysis; it does not change candidates or matches. Production uses
`ConfiguredDescriptionSearchEngine(.productionDefault)` and asserts that the
current default is BM25. The structured comparator also runs through the service.
There is no semantic/CoreML engine or fallback in these results.

All eight Caribbean and 384 Pacific profiles participate in development search.
BM25 admits at most 50 candidates; structured search admits the entire selected
pack. Candidate recall counts target admission before biological ranking. Top-k
counts final service results among 34 positive cases, regardless of candidate
recall. The two ambiguous cases use acceptable sets and are reported separately;
they cannot inflate primary-identity accuracy. Multiple plausible biological
species may share these descriptions, particularly unbundled relatives.

Publication uses actual verified profiles, never a synthetic promotion. Both
regions currently have zero eligible records. Each of 46 requests is attempted
per engine selection and receives the catalogue-unavailable diagnostic before
engine execution. These are coverage-blocked requests, not successful no-matches.
All publication quality denominators are zero and gates say **not-evaluated**.
When a future partial subset exists, missing expected identities are excluded
from quality denominators and counted as coverage-blocked; any returned results
remain in the case report. The suite does not claim out-of-catalogue detection for
those excluded positive targets.

## Results

Debug repeat and Release produced byte-identical reports. Results use the full
pack and the fixed v2 fixture; there were no evaluation-driven engine edits.

| Engine | Candidate recall | Top-1 | Top-3 | Top-10 | Correct no-match | Correct regional conflicts |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Production BM25 + biological | 33/34 | 22/34 | 28/34 | 30/34 | 4/6 | 2/4 |
| Structured comparator | 34/34 | 16/34 | 21/34 | 24/34 | 4/6 | 2/4 |

| Development region | Size | Production recall | Production top-1/3/10 | Structured top-1/3/10 |
| --- | ---: | ---: | --- | --- |
| Caribbean | 8 | 16/16 | 14/16, 16/16, 16/16 | 11/16, 15/16, 16/16 |
| Tropical Pacific | 384 | 17/18 | 8/18, 12/18, 14/18 | 5/18, 6/18, 8/18 |

Each engine executes 46 development requests and zero publication requests past
the catalogue gate. Ambiguous acceptable-set coverage is 2/2 for production and
1/2 for structured. Scores are relative matches, not calibrated probabilities.
All returned scores stay finite in [0,1]; limited-information scores and ambiguous
case scores stay <=0.64. Confidence-contract compliance is 44/46 because the two
explicit no-match cases require no result (maximum score zero) but return results.
This must not be read as 44 correctly calibrated probability estimates.

The complete Debug and Release suites each execute 108 tests with one opt-in skip;
only the new evaluation test fails, with 30 assertions (case requirements plus
aggregate gates across both engines). Every prior gate remains green. All 75
Python tests across six suites pass. Failure does not suppress later cases,
publication checks, report writing, or CI artifact retention. Xcode/simulator and
physical-device behavior have not been executed locally.

## Specific follow-up defects — no fixes in this pass

- `v05-17-paraphrase`: Cockatoo Waspfish misses production's 50-candidate pool.
  The existing, different waspfish fixture still passes. Investigate lexical
  paraphrase/measurement retrieval rather than increasing the pool for one case.
- `v05-09-paraphrase`: Bird Wrasse is retrieved first but absent from displayed
  results. `v05-10-paraphrase`: Black Triggerfish is retrieved 23rd but absent.
  These are retrieved-not-displayed failures; the report does not claim to
  distinguish individual ranker rejection from falling below its top-ten truncation.
- `v05-13-diagnostic`: Orangeband Surgeonfish is retrieved 11th, but **all**
  candidates are rejected by biological ranking. Rich identification text is
  retrieved without enough surviving structured evidence.
- Both terrestrial probes describe a spotted freshwater frog with sand and size
  clues. Both engines return marine candidates: out-of-domain intent is not
  outweighing generic visual/habitat evidence. These are real false positives.
- Region probes 2 and 3 fail to recognize Philippines and Bahamas; captured
  observedRegions is empty. Existing token singularization and controlled-region
  handling need investigation. Fiji and Caribbean conflicts are recognized.
- Structured Pacific comparison misses additional triggerfish/anemonefish cases
  and fails the overall top-ten floor (24/34, below 80%). Catalogue/parser evidence
  coverage needs a separate diagnosis; do not lower these floors to pass it.
- Publication eligibility remains zero. Broader synthetic development success
  cannot demonstrate Release identification quality until real human decisions
  approve source-reviewed records.

## Reproduce and retain evidence

```sh
python3 Tools/Evaluation/run_v05.py --configuration debug
python3 Tools/Evaluation/run_v05.py --configuration release \
  --output /tmp/v05-release.json --log /tmp/v05-release.log
cmp Reports/V05DevelopmentEvaluation.json /tmp/v05-release.json
python3 -m unittest discover -s Tools/Evaluation -v
swift test
swift test -c release
```

The runner defaults to v2 and accepts `--version 1` for auditing the original
mapping. Pass a separate output/log path when doing so. It verifies the frozen
fixture hash, removes stale output before execution, retains the complete log and
JSON report even when assertions fail, and returns the failing test exit status.
The Swift test also checks the hash when invoked directly. Reports contain loaded
profile fingerprints, pool sizes, target retrieval positions, displayed IDs/rank,
confidence values, region analysis, actual engine execution and per-case failures.
Do not interpret “rankedCandidates” as proof that the expected identity survived.

CI's existing SwiftPM jobs run the new test as a mandatory check and always retain
its JSON report alongside the log. Python contract tests run in their own job.
`Reports/V05Validation.json` records reproduction hashes and test totals; the
committed result is `Reports/V05DevelopmentEvaluation.json`.

`Data/Evaluation/IndependentDiverCollection.md` is an empty 12-observation pilot
collection template. It asks for unedited, consented, independently written text
without exposure to examples or engine output; independent identity adjudication;
and a frozen manifest before evaluation. Keep those submissions outside tuning.
There are currently **zero** independently collected diver descriptions in this
new suite. Shared facts, similar wording and repeated regional probes make these
cases correlated, so the reported fractions are development diagnostics, not
population estimates or evidence of unbiased field performance.
