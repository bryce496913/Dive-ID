# Retrieved-target ranking correction

Baseline main `4200d4b853b0cb8d6bc36c4cd892c0ed57022a82`, tree `7eeeaea6db8b3b9d2b90c4a651585c1679eb72fe`, includes merged location and domain repairs. Started on a clean local `codex/domain-contradictions` with that exact tree; work branch `codex/evidence-ranking`. No applicable AGENTS.md was found.

## Fresh failures and trace

A new frozen-v2 application-service evaluation reproduced 16 assertion failures. The failure list was derived from that report, not copied from the previous pass. Production retrieved Bird Wrasse, Black Triggerfish and Orangeband Surgeonfish inside its 50 candidates but did not display them. Cockatoo Waspfish was a separate retrieval miss at rank 67. Structured search had additional ranking failures.

`RankingEvidenceEvaluation.json` records every affected case, including BM25 retrieval rank/score/terms, normalized relevance, pool survival, structured support/contradictions, eligibility, ordering score, relative match score, pre-presentation rank and displayed rank. The three leading competitors are retained. Scores for targets outside the production pool are explicitly diagnostic-only, not application execution. Structured search admits the whole pack; its lexical ranks are BM25 diagnostics, not retrieval performed by that engine.

The opt-in `testTraceRetrievedRankFailures` singleton-scores candidates to inspect ranks beyond ten without raising application limits, then asserts the engine's actual top ten match that ordering. It asserts that the service preserves order. The final trace also replays real service results through `IdentificationResultsViewModel`, checking IDs, ranks and scores survive normalization. There is no presentation removal/reordering defect: the service emits unique IDs and sequential ranks, and the model sorts by those ranks, deduplicates and caps at ten.

## Root causes and changes

1. Numeric `deep` and `long` modifiers leaked into independent habitat/body-shape clues. Bird Wrasse's query at 10 m acquired a deep-water habitat mismatch: blue/green contributed six points, the false habitat contradiction removed three, and score 3 failed threshold 4. Measurement-role words now contribute only to their measurements; independently stated long bodies and deep-water habitat remain recognized.
2. `no bright pink tail` supplied positive tail evidence, granting unrelated tail-tagged candidates four points over Black Triggerfish. Explicit no/not/without clauses no longer assert positive traits or exact names. Later clauses and `not only` additive wording are retained. Compound negation is not decomposed into unsupported anatomical absence: no pink tail does not imply no tail. This remains a bounded phrase policy, not a full discourse/negation parser.
3. Singular `patch` was missing from the patches synonym group. Orangeband's description therefore had only a color group and was rejected as insufficient before scoring. The general singular/plural mapping now supplies the existing marking concept.
4. Empty catalogue habitats were treated as contradictory rather than unknown. Empty habitats are now neutral; actual incompatible nonempty habitats still receive the existing penalty. Size, region, domain, eligibility and confidence contracts remain enforced.
5. Partial identity terms such as triggerfish were available to BM25 but absent from structured evidence when draft keyword arrays were empty. The ranker now recognizes shared words from existing common/scientific names and aliases using the existing weak keyword weight of one, labelled `identity term`. Trait/synonym words and existing keywords are excluded to avoid duplicate evidence; a partial name cannot bypass information eligibility or receive the exact-name weight. This applies to all catalogue identities, without species lists or boosts.
6. Five source-backed overlays fill missing controlled traits: Orangeband patches/compression; Redtooth schooling; Pinktail yellow; Red-and-Black Anemonefish red/yellow/bars; Spinecheek brown/bars. No evaluation prose was copied into documents. Source-backed fields flow through the existing validated importer, preserving stable IDs and original provenance.

No numeric weights, production BM25 selection, candidate limit (50), result limit (10), confidence cap, evaluation description, case/expected ID, acceptable rank, split or threshold changed. Retrieval relevance retains its BM25 saturating normalization; structured/identity evidence contributes raw evidence score; ordering retains relevance and occurrence terms; user-facing strength retains the relative-evidence score and information cap. Partial name evidence is not semantic inference.

## Before/after ranks

`—` means not displayed. Each lexical rank is before → after. Structured admits the full 384-record Pacific pack. The ambiguous case shows the best accepted species; all three targets are in the JSON trace.

| Case | Target | BM25 retrieval | Production displayed | Structured displayed |
| --- | --- | --- | --- | --- |
| v05-09-paraphrase | Bird Wrasse | 1 → 1 | — → 3 | — → 6 |
| v05-10-paraphrase | Black Triggerfish | 23 → 23 | — → 6 | — → 3 |
| v05-11-diagnostic | Pinktail Triggerfish | 1 → 1 | 3 → 1 | — → 1 |
| v05-11-paraphrase | Pinktail Triggerfish | 4 → 4 | 1 → 1 | — → 2 |
| v05-12-diagnostic | Redtooth Triggerfish | 4 → 1 | 2 → 1 | — → 1 |
| v05-12-paraphrase | Redtooth Triggerfish | 1 → 1 | 10 → 2 | — → 2 |
| v05-13-diagnostic | Orangeband Surgeonfish | 11 → 11 | — → 1 | — → 1 |
| v05-15-diagnostic | Red and Black Anemonefish | 1 → 1 | 3 → 1 | — → 1 |
| v05-16-diagnostic | Spinecheek Anemonefish | 1 → 1 | 3 → 1 | — → 1 |
| v05-17-paraphrase | Cockatoo Waspfish | 67 → 67 | — → — | — → — |
| v05-ambiguous-trigger | Accepted triggerfish group | best 1 → 1 | 1 → 1 | — → 1 |

All retrieved-target failures except the structured Waspfish paraphrase now satisfy their unchanged bounds. Waspfish remains outside the production pool; structured pre-limit rank improves 62 → 53 but still exceeds ten. The parser does not recognize the paraphrase's leaflike/dorsal-height relationship, and the record's existing leaf-mimicry prose and sail-like fin field do not transfer into matching structured clues. The ranker sees fish and compatible depth (eight points), not distinguishing morphology. This is an unresolved descriptive-evidence/retrieval limitation, not a missing authoritative account: the prior Fishes of Australia/Australian Museum evidence remains available. The original Pacific positive fixture still passes; no synonym or limit was introduced solely for this paraphrase.

## Source evidence and remaining data questions

Exact fields, references, sections, inspection dates and corrected-content fingerprints are in `RankingSourceEvidence.json` and the overlay. Authoritative accounts inspected:

- [FishBase: Acanthurus olivaceus](https://www.fishbase.se/summary/Acanthurus-olivaceus.html), Short description and body shape: localized orange marking and compressed cross section.
- [FishBase: Odonus niger](https://www.fishbase.se/summary/Odonus-niger.html), Biology: feeding schools.
- [Fishes of Australia: Melichthys vidua](https://fishesofaustralia.net.au/home/species/765), Summary: yellowish snout/pectoral fin.
- [Fishes of Australia: Amphiprion melanopus](https://fishesofaustralia.net.au/home/species/1274), Summary/Colour: red/yellow areas and head bars.
- [Fishes of Australia: Amphiprion biaculeatus](https://fishesofaustralia.net.au/Home/species/378), Summary: brownish coloration and pale bars; explicitly connects the retained Premnas name to Amphiprion.

Original book pages remain unavailable; original citations and transcription are retained. Replacements were inspected only for corrected traits, not full-record publication approval. In particular, Spinecheek's legacy maximum 3 cm conflicts with the replacement accounts' 16 cm TL (Fishes of Australia) / 17 cm TL (FishBase); resolving that measurement context remains a separate source-review question. Pink remains absent from the controlled color vocabulary rather than being coerced into red. No name/measurement inference was added to rescue an evaluation case. All 392 records remain draft, with zero publication-eligible records.

## Validation

Swift 6.2.3, Linux x86_64, Debug: full suite executed **124 tests**, one platform skip, **two failing assertions**, both the unchanged v05-17-paraphrase bound (production and structured). Baseline had 16 failing assertions. All older Caribbean/Pacific quality gates, domain/location tests, persistence/lifecycle tests and new evidence tests pass. All versioned aggregate floors now pass; the two per-case failures still fail the suite. The completed presentation trace was then rerun after adding result-model replay assertions and passed. No historical diagnostic assertion needed weakening; all acceptance assertions remain intact.

Per engine, 46 development service calls run against 8 Caribbean + 384 Pacific records:

| Metric | Production before → after | Structured before → after |
| --- | --- | --- |
| Candidate recall /34 | 33 → 33 | 34 → 34 |
| Top-1 /34 | 22 → 27 | 16 → 23 |
| Top-3 /34 | 28 → 31 | 21 → 30 |
| Top-10 /34 | 30 → 33 | 24 → 33 |
| Ambiguous accepted /2 | 2 → 2 | 1 → 2 |
| No-match /6 | 6 → 6 | 6 → 6 |
| Region conflict /4 | 4 → 4 | 4 → 4 |
| Confidence compliant /46 | 46 → 46 | 46 → 46 |

Publication remains coverage-blocked for all 46 cases with zero engine invocations in each engine. Python: 19 catalogue-review, 6 importer and 3 frozen evaluation-contract tests pass. The existing reproducibility verifier completed two byte-identical catalogue/report regenerations; hashes updated in SourceReviewReproducibility.json. `git diff --check` passes.

Reproduce a fresh evaluation and derive its failure trace:

```sh
DIVEID_V05_REPORT=/tmp/ranking-evaluation.json swift test --jobs 4 --filter testVersionedDevelopmentEvaluationThroughApplicationService
DIVEID_RANK_TRACE_BASELINE=/tmp/ranking-evaluation.json DIVEID_RANK_TRACE_REPORT=/tmp/ranking-trace.json swift test --jobs 4 --filter testTraceRetrievedRankFailures
swift test --jobs 4
python3 -m unittest discover -s Tools/CatalogReview -p 'test_*.py'
python3 -m unittest discover -s Tools/CatalogImport -p 'test_*.py'
python3 -m unittest discover -s Tools/Evaluation -p 'test_*.py'
python3 Tools/CatalogReview/verify_source_review_reproducibility.py
```

Run the commands independently: the evaluation/full suite intentionally exit nonzero while the Waspfish failure remains. To compare this pass's original cases, preserve the baseline report as the trace input. Session logs and full reports are `/tmp/rank-before.{log,json}`, `/tmp/rank-after.{log,json}`, `/tmp/rank-trace-before.json`, `/tmp/rank-trace-after.json`, and `/tmp/rank-presentation-trace.log`. Xcode/hosted-only, simulator/UI and device validation were unavailable and are not claimed.
