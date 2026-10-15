# Draft expansion validation — 2026-10-15

Base: `4ecf013edd9548913f6744e0a82ecf36d31c85a1`. Input source commit:
`e7cedab82e9deaae8bcc06f8cf4d09e6504f74a5`.
The containing commit identifies the tested integration; resource hashes are in
`SourceReviewReproducibility.json` and the evaluation report records loaded profile
fingerprints and the frozen fixture hash.

- All 384 baseline records compare equal by UUID and full decoded content.
- All 616 supplied records compare equal by UUID and full decoded content.
- Pacific version 3: 1,000 development records, zero approved. Overall: 1,008
  records, 1,006 drafts, two approved Caribbean records; exact publication IDs and
  reproduction commands are in `Docs/TropicalPacificExpansionImport.md`.
- Two byte-identical regenerations passed for all ten generated artifacts.
- Python: 98 tests passed (CI 9, importer 10, review 25, evaluation 12, workbook 9,
  semantic tooling 33). Duplicate identities, normalized UUID collisions, draft
  enforcement, audit mismatch, untouched output on invalid input and pair rollback
  are covered.
- Swift 6.2.3 Linux Debug and optimized Release: each executed 129 tests, three
  skips, four failed assertions across three search tests. Exact publication-set
  and accounting checks passed in both. Hosted iOS and device tests unexecuted.

Failures remain visible; neither ranking nor frozen acceptance changed:

1. `testSourceCorrectionsSurviveRetrievalAndBiologicalRanking`: Fire Dartfish
   displayed 6 instead of the diagnostic's 5.
2. `testVersionedDiverDescriptionsThroughProductionIdentificationService`:
   `pacific-v1-fire-dartfish` displayed 6, exceeding its unchanged maximum 5.
3. Frozen v2 `v05-14-paraphrase`: target absent from BM25's 50 candidates and
   displayed results; full-pack structured comparator includes it but also misses
   its displayed-rank requirement (one assertion per engine).

The complete unchanged 46-case evaluation is retained in
`TropicalPacificExpansionEvaluation.json`. Production BM25 plus biological ranking
against development coverage: candidate recall 33/34, top-1 27/34, top-3 32/34,
top-10 33/34; no-match 6/6, region conflict 4/4, ambiguity 2/2. Publication coverage:
36 cases blocked by unavailable species/regions; 10 applicable cases, positive
recall 4/4, top-1 3/4, top-3/top-10 4/4, no-match 3/3, conflict 2/2, ambiguity 1/1.
These are development regression fixtures, not independent accuracy evidence.

Caribbean quality tests passed. Production engine and publication decisions are
unchanged. Search regressions block declaring the expanded development pack green;
resolve them in a separate source-backed diagnosis without weakening gates.
