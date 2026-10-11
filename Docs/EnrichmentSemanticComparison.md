# Development enrichment and real-encoder comparison

Status: preparation only, 2026-10-11 UTC. No independent development export or
baseline has been supplied. Do not select an enrichment batch from synthetic
regressions as a substitute for the requested independent failure analysis.
Production remains BM25 with biological ranking. This document is not promotion approval.

## Inputs and leakage boundary

The custodian first supplies the frozen baseline manifest and an explicitly released
**development-only** export from IndependentDiverCollection.md. Keep original IDs,
identities, descriptions, split assignments and acceptance bounds. Archive the original
catalogue bytes and baseline before changing anything. Record hashes for dataset,
protocol, candidate SHA, catalogue/manifest, search-document schema, ranking code and
parameters. Reconcile linked-author/encounter exposure history across dataset versions.
Do not open holdout wording, identities or case-level results in development tools.
A cohort used for enrichment is development permanently, even if it was once holdout.

## Classify before editing

Use the application service's captured candidate pool and final results for each
released development failure. Keep this case-level ledger private with the export:

| Class | Required evidence before assigning |
| --- | --- |
| Catalogue | An inspected source supports a missing/incorrect identity-critical field; record exact citation, quoted evidence and current field. Vocabulary absence alone is not source evidence. |
| Parsing | The observation explicitly states a supported concept but normalized/structured observations lose or misinterpret it. Include negation, comparison and location context. |
| Retrieval | The expected record has supported searchable evidence but is absent from the configured 50 candidates. Record rank/relevance and the pool boundary. |
| Ranking | Expected ID survives retrieval but biological support/contradictions, eligibility or ordering misses its unchanged bound. Keep relevance, ordering and match strength separate. |
| Presentation | Service normalization, displayed limit or results model removes/reorders a correctly ranked result. Compare engine, service and displayed IDs. |

Record multiple causes where justified; otherwise mark unresolved. Unknown source
traits stay neutral. A low rank alone does not establish a catalogue defect.
Parser/ranker defects belong in separate focused repairs, not this enrichment experiment.

Select at most five existing records from source-evidence failures, prioritizing
accessible authoritative accounts. For each, retain stable ID, original provenance,
source URL/title/access date and supporting passage, field-level before/after values,
unresolved questions and before/after reviewed-content fingerprints. Do not reuse diver
wording as catalogue prose. Apply through the existing correction/import overlay and
CatalogReview tools. Material content changes invalidate stale reviewed fingerprints;
only a real human decision covering the new content permits verified status. Keep
unsupported or unapproved records draft. Run
`python3 Tools/CatalogReview/verify_source_review_reproducibility.py` after approved
edits and inspect its two identical regeneration passes. Never expand the staging pack
as part of this bounded experiment.

## Isolate enrichment from retrieval changes

| Run | Catalogue | Retrieval | Other inputs |
| --- | --- | --- | --- |
| A | Original frozen bytes | BM25 | Same development cases, biological ranking, limit 50 and display limit 10 |
| B | Source-enriched bytes | BM25 | Identical to A except catalogue |
| C | Same enriched bytes as B | Genuine frozen Core ML encoder | Identical cases/ranking/limits; matching newly generated index |

A→B measures enrichment. B→C measures retrieval choice. Retain A even if B worsens.
Never reuse A's embedding index after enrichment. Report each region and publication
access separately; absent targets/regions are coverage-blocked, not successful no-match.
Use the intersection of identical eligible cases for paired comparisons, and separately
report excluded coverage; do not silently change denominators after a review promotion.

Report candidate recall at 50 independently from top-1/3/10 and per-case rank bounds,
no-match false positives, regional mismatch, ambiguity and confidence caps. Include
paired gains/losses, total cases, eligible positives and policy-class denominators.
For packs smaller than k, label recall@k saturation as non-informative about large-pack
retrieval. Do not treat relative strengths as probabilities. Cluster uncertainty by
independent author/encounter cohort; small samples are descriptive, not promotion evidence.

Preserve IndependentProtocol.v1 and every existing regression gate. Before untouched
holdout, freeze all identities, exclusions, comparison acceptance and device budgets.
Require zero new policy/confidence failures and no degradation of final quality for a
retrieval improvement claim; report paired recall change and uncertainty rather than
calling a tiny raw gain superiority. Production promotion requires a separate decision
under production-readiness.v1.json, whose missing thresholds cannot be filled after
seeing holdout. Custodian publishes aggregates only; exposed holdout cohorts become
new development data before any further tuning.

## Genuine encoder and Apple execution

Use the existing `real-encoder.v1.json`: all-MiniLM-L6-v2 revision
`c9745ed1d9f207416be6d2e6f8de32d1f16199bf`, 384 dimensions, 256 tokens, uncased
accent-stripping WordPiece, end truncation, CLS/SEP, masked-mean pooling, L2 normalization,
no prefixes, Float16 Core ML ML Program, iOS 18. Do not substitute random/test vectors.

On an authorized networked Mac with Xcode and Python 3.12:

```sh
python3 -m venv .venv-real-encoder
. .venv-real-encoder/bin/activate
python3 -m pip install -r Tools/SemanticSearch/requirements-real-encoder.txt
python3 Tools/SemanticSearch/provision_real_encoder.py \
  --package-resources DiveID/Resources/SemanticSearch
python3 Tools/SemanticSearch/validate_production_readiness.py \
  Tools/SemanticSearch/production-readiness.v1.json \
  --provisioning-evidence DiveID/Resources/SemanticSearch/provisioning-evidence.json \
  --packaged-resources DiveID/Resources/SemanticSearch
```

The provisioner currently targets Caribbean. Do not label Pacific fallback a semantic
comparison or expand provisioning merely to fill a table. First validate this bounded
pack and describe its eight-record recall saturation. Archive actual upstream hashes,
tokenizer/vocabulary/preprocessing fingerprints, compiled-model tree hash, corpus/index
fingerprints and packaged app resource identities. Older README corpus hashes are
historical; regenerate from each frozen catalogue and use actual outputs.

`evaluate_candidate.py` audits supplied reference/Core ML vectors and numerical parity;
it does **not** run the identification comparison or measure Apple hardware. The
independent custodian runner currently runs production BM25 only. Once real artifacts
exist, a development-only comparison adapter still needs to inject
`ConfiguredDescriptionSearchEngine(selection: .experimentalCoreML)` through the same
service and collect every `SemanticRetrievalMetrics` event. A latest-value diagnostics
store alone cannot establish run totals. Do not claim those adapters or measurements
have already executed.

Track semantic requests, genuine Core ML successes, typed BM25 fallbacks, failures,
service policy rejections before retrieval, cache hits and cancellations separately.
Partition results by actual engine. Fallbacks count in operational reliability, never
in semantic recall/quality. Retain the same paired denominator and mark the experiment
incomplete when genuine execution is missing; do not improve semantic scores by dropping
hard fallback cases. Test fixtures with injected fake providers prove contracts only.

For parity, retain existing component-error ≤0.001, cosine ≥0.999 and zero top-10
changes unless a separately versioned development decision is frozen first. Verify
packaged resources again inside the actual built app using the documented validator.

## Hardware measurement record

Record SHA, app version/build, Xcode, model/index hashes, device model/OS, catalogue and
engine for every run. Simulator and physical iPhone are separate cohorts. On-device
networking must be disabled. Measure monotonic request start → displayed result for
end-to-end latency, with embedding/retrieval phases separately. Use five independent
cold process launches plus 30 warm searches in a fixed development-only order; report
all sample counts, median, nearest-rank p95 and range (cold p95 is descriptive only).
Record cache hits; test cached repetition separately. Instruments records resident-memory
baseline/peak/delta across repeated searches; sum compiled resource bytes and record
archive/app sizes separately. Measure cancellation request → task termination and prove
no stale UI update after immediate restart. Do not infer these from Linux timings.

The existing proposed oldest-device budgets remain unmeasured: initialization 2,000 ms,
first search 1,000 ms, warm median 250 ms / p95 500 ms, incremental memory 200 MiB,
assets 100 MiB, cached repeat 100 ms, cancellation 250 ms, no main-thread stall >100 ms.
Freeze device choice and budgets before holdout. No distribution or production engine
change follows automatically from passing an experiment.
