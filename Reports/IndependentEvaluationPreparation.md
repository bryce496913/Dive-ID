# Independent diver evaluation preparation

## Twelve-case pilot status — October 14, 2026

Inspected main `e3f1237ef7d89b80ef73518d97078f76d02b98f8` and the existing
collection form, independent-v1 protocol, importer, private service-path runner
and fixture-exposure inventory. No applicable AGENTS.md was found. No independently
authored submissions were supplied in the repository or attached workspace files.
No outreach was performed or participant identity invented.

| Measure | Actual status |
| --- | --- |
| Target | 12 accounts: 4 Caribbean, 8 Pacific |
| Collected / imported | 0 / 0 |
| Independently verified / unresolved submitted labels | 0 / 0 |
| Remaining submissions | 12 |
| Frozen human dataset / BM25 baseline | Unavailable / unexecuted |
| Candidate recall, ranks, abstentions, confidence | Unavailable; no denominators |
| Catalogue coverage now | Development 392; publication 2 Caribbean, 0 Pacific |

The existing collection document now specifies intake, consent, separate evidence
review, context retention, whole-pilot development exposure, private preflight,
freeze/evaluate and a prospective larger sampling plan. No protocol thresholds,
frozen descriptions, ranking, catalogue content or approval changed. The pilot
will use the same importer and application service runner, not a parallel framework.

Added `preflight` to the existing importer. It does not search, freeze, or expose
case details. It reports the 12-case/region target, declared verification status,
alternatives/unresolved labels, contributor counts, missing context, unrecorded
publication consent and development/holdout counts. It cannot prove human
authorship, consent, independent evidence quality or undisclosed exposure.

Workflow findings before real collection:

- The existing form and importer already preserve wording, stable IDs, alternative
  identities and frozen original provenance. No genuine wording or identity audit
  can be performed without submissions and their separately permissioned evidence.
- Publication consent and observation context previously had no pilot completeness
  summary. Preflight now reports these gaps; refusal of publication is not rejection
  of evaluation consent. Context is retained privately and never added to queries.
- A process-development pilot needs an explicit exposure policy: mark all pilot
  cohorts development before freeze, retain the ledger, and use fresh cohorts for
  later independent holdout. Do not inspect holdout wording in this chat.
- A 12-row import is neither 12 independent participants nor 12 verified identities.
  Distinct-author and unresolved counts must accompany any later pilot report.
- Import tests only establish declared-schema behavior. Human verification and
  ambiguity quality remain unassessed; no independent accuracy claim is possible.

Validation: 12 Python evaluation tests pass, including empty/missing input behavior,
12 explicitly synthetic schema rows, privacy-preserving summaries, separate verifier,
alternatives/unresolved labels, cohort exposure and immutable freeze checks.
Synthetic test rows were not collected or imported as human pilot data and were
not used to measure search quality. The CLI empty-input preflight and freeze
rejection were exercised without invoking the engine. Frozen fixture checks pass.

Missing input: 12 real, unedited, consented English accounts; collection dates,
participant/encounter/cohort codes, broad region/context and exposure declarations;
separately accessible identity evidence, a different verifier's actual adjudication
and uncertainty; and a named authorized custodian/private storage location. Supply
those privately through the existing schema, or authorize a specific collection
process and channel. No outreach is authorized merely by preparing these materials.

Before expansion, review the proposed staged 400-account sampling plan in
IndependentDiverCollection.md. It preserves v1's deterministic cohort split and
minimum denominators; sparse labels/publication coverage remain limitations, not
reasons to manufacture cases or lower gates. Collection and the real 12-case pilot
remain outstanding. Stop before enrichment, ranking changes or model selection.

## Historical initial preparation

Prepared 2026-10-11 UTC against main b07e83ac6c7800244ca68ff8755fbce9fa7203d6.
This PR adds collection/import/evaluation infrastructure only; it does not enrich the
catalogue, tune ranking, select a model, or change existing fixture expectations.

## Provenance and baseline status

Collected independent descriptions: **0**. Imported independent cases: **0**.
Independent candidate recall, final-rank quality, no-match error, ambiguity and
confidence results: **unavailable**, with zero denominators, not a successful baseline.
Existing implementation-exposed fixtures are inventoried in Data/Evaluation/FixtureExposure.md.

The collection form separates unprompted recollection from independent identity
verification. Versioned criteria fix cohort splits and acceptance before evaluation.
The importer preserves stable observation-derived case IDs, alternatives, unresolved
labels and private original provenance. A clean committed checkout, catalogue hashes,
protocol hash and dataset hashes bind each baseline; execution records Swift version.
Raw logs and case results remain in a private external directory. Aggregate reports
separate access and split, coverage blocks, denominators, candidate recall, top-1/3/10,
no-match false positives, ambiguity, regional conflicts and relative-strength limits.
Small samples report insufficient sample; strengths are not calibrated probabilities.

## Validation

- Linux Swift 6.2.3: full suite 129 tests, 3 expected skips, zero failures.
  Includes existing Pacific, Caribbean and frozen v0.5 gates. The new custodian runner
  skips without supplied input; the other skips are opt-in trace and hosted-only checks.
- Python evaluation tooling: 9 tests passed, including six new synthetic contract tests.
- External runner smoke test: four existing synthetic development descriptions,
  one each positive, ambiguous, no-match and region conflict; one test passed.
  Eight access-specific rows: four development service executions, four publication
  coverage blocks. This is plumbing evidence, **not independent quality evidence**.
- Actual development pack: Caribbean 8, Pacific 384 (392 total).
  Actual publication subset: zero in each region. No synthetic approval used.
- Xcode/device checks not executed on Linux; this pass changes no app runtime behavior.

## Collection requirements

An authorized custodian must obtain consenting divers’ own unprompted English wording,
collection dates, author/encounter grouping and exposure declarations. A different
verifier establishes labels from traceable evidence without app results, retaining
alternatives or unresolved labels. Follow the exact freeze/evaluate commands in
Data/Evaluation/IndependentDiverCollection.md from the committed candidate.
Do not disclose holdout wording, identities, per-case failures or logs to developers.
No outreach has been performed. Real collection, independent quality evidence and
publication-subset evaluation remain outstanding. Stop before enrichment/model selection.
