# Independent diver evaluation preparation

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
