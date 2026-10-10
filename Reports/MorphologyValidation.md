# Morphology contract and validation

Baseline main: `85b55c8f7daa2d6874f12c0bef1fd21fe5e5b072` (tree
`235d34110869be92be078c475e15c1411fd03e6e`). No applicable AGENTS.md found.
Production remains BM25 plus biological ranking, 50 candidates / ten displayed.
Frozen v0.5 v2 descriptions, identities, rank bounds, thresholds and splits are unchanged.

## Contract

`leaflike` is a controlled body-shape value in Swift and Python validation. Query
forms include leaflike, leaf-like, leaf-shaped and body shaped like a leaf, with
explicit body/animal/fish scope. A leaflike dorsal fin or an animal among leaves
is not a leaflike body. A short intervening modifier is allowed. Unrecognized
wording stays unknown.

Fin morphology lives in `finAndSpineClues`: `tall dorsal fin` (height),
`sail shaped dorsal fin` (outline), `filamentous dorsal fin` (elongated filament).
High/elevated/raised, sail-like, threadlike, streamer and inverse phrasing map to
these concepts in the shared morphology vocabulary. No implication from height to
sail outline, leaflike body, or spines is introduced. Explicit spine observations
continue through the separate existing marking group. Negated morphology contributes
no positive structured evidence. No new negative morphology penalties are added:
unknown or omitted traits and a different fin descriptor do not prove absence.

Search documents already include bodyShapes and finAndSpineClues. BM25 now uses
the same scoped concept normalization for documents and queries and counts each
canonical morphology term at most once per document/query. Biological body evidence
uses the existing weight; fin morphology contributes at most one existing two-point
fin evidence group, regardless of aliases. It also reaches the observation
information-sufficiency check. Retrieval relevance, biological score, ordering and
user-facing match strength remain separate; confidence caps and contradictions
remain intact.

The workbook importer deliberately leaves body/fin enrichment empty. Automatic
unreviewed extraction from arbitrary OCR prose is not introduced. Source-inspected
corrections enter those fields through the existing validated overlay, followed by
normal import generation. The Python vocabulary accepts the same canonical body
concept as Swift. No source spelling aliases are copied repeatedly into catalogue
text to inflate retrieval.

## Source-backed corrections

Cockatoo Waspfish (`5f4d48f4-6556-50f3-95af-a4d28635f4bb`):
[Fishes of Australia, Summary and Features](https://fishesofaustralia.net.au/home/species/3205)
supports elevated anterior dorsal morphology;
[Australian Museum, Identification](https://australian.museum/learn/animals/fishes/cockatoo-waspfish-ablabys-taenianotus-cuvier-1829/)
supports the sail outline. Retain compressed body, normalize sail wording and add
height. Swaying like leaves is behavioral mimicry; these inspected accounts do not
establish a separate leaflike-body assertion, so none is added.

Fire Dartfish (`7a662be3-854f-5819-8d32-cb8b1f19a00b`):
[Fishes of Australia, Features](https://fishesofaustralia.net.au/home/species/2943)
supports elevated, filamentous first dorsal morphology. Add height and filament
concepts without transferring them to body shape or inventing a spine observation.
Original source entries/IDs remain intact. Added references and corrected fingerprints
are in MorphologySourceEvidence.json and the review overlay. Both records remain
draft; all 392 records are still excluded from publication access.

## Evidence and limits

MorphologyEvaluation.json contains before/after complete service evaluation output
and detailed target traces for the baseline failure. The baseline trace was rerun
from an isolated archive of the baseline source tree. Trace fields distinguish a
retrieval miss, candidate-limit survival, biological eligibility, ordering before
the display limit and service/result-model preservation. Structured full-pack
`retrievedTargetRanks` are enumeration positions, not lexical relevance ranks;
use the detailed trace's `lexicalRetrievalRank` for BM25 comparisons.

Focused tests cover both corrected species, synthetic leaf-body fixtures (not
publication approvals), paraphrases, fin/body separation, negation, unknown-trait
neutrality, and alias score deduplication. Historical source diagnostics now assert
the canonical fin evidence while retaining candidate-survival and acceptance checks.

No inspected evidence in this pass justifies adding leaflike body shape to a real
bundled record. That is an explicit source-data limit, not permission to infer it
from a species name or fin outline. New body-shape data needs a traceable account
and overlay correction. Xcode/device validation is unexecuted on this Linux host.


## Final results

Linux Swift 6.2.3: **128 tests, one hosted-only skip, zero failures**. Includes the
complete frozen evaluation, Caribbean and Pacific quality gates, persistence and
historical saved-record tests, and before/after normalization diagnostics. Python:
19 review + 6 import + 3 frozen evaluation-contract tests pass. Two full catalogue
regenerations are byte-identical. No acceptance assertion was relaxed.

| Case / engine | Before retrieval → after | Before displayed → after | Evidence |
| --- | --- | --- | --- |
| v05-17-paraphrase / production BM25 | 67 → 15 (limit 50) | absent → 2 | Eligible biologically in both; now selected; tall dorsal adds 2 points |
| v05-17-paraphrase / structured diagnostic | full 384 pool both | 53 before display limit → 1 | Biological score 8 → 10; no contradictions |
| v05-17-diagnostic / production BM25 | 2 → 2 | 1 → 1 | Compressed body plus recognized dorsal height |
| pacific-v1-fire-dartfish / production BM25 | 1 → 1 | 5 → 5 | Eligible; fish, tail, red, hovering; no morphology asserted by this query |
| pacific-v1-cockatoo-waspfish / production BM25 | 3 → 1 | 1 → 1 | Eligible; fish, brown, canonical sail-shaped dorsal evidence |

Waspfish paraphrase normalized retrieval relevance increases 0.6514 → 0.7003;
ordering score 13.2114 (diagnostic outside old pool) → 15.6024; relative match
strength remains modest (0.1905 → 0.2381). Leaflike observation is recognized but
gives this species no body-shape credit because that field remains unsupported.
Service and results-model normalization preserve ordering and scores.

Production development evaluation: 46/46 service calls; candidate recall 34/34
(previously 33/34), top-1 27/34, top-3 32/34, top-10 34/34. All individual rank bounds
and versioned gates pass. No-match 6/6, location conflicts 4/4, ambiguity 2/2,
confidence limits 46/46. Structured diagnostic evaluation also passes all gates.
These are synthetic development descriptions, not independent diver holdout data.
Publication evaluation: zero engine calls, all 46 cases coverage-blocked because
there are no approved records. Passing development gates is not publication approval.
