# Real encoder production-readiness evaluation — 2026-09-06

## Decision

**Continue experimenting; do not promote.** The production default remains BM25. No genuine encoder, matching Core ML model, or compatible precomputed catalogue index is present in this checkout. There was therefore no real-model provider usage to measure; semantic accuracy, parity, device performance, and offline operation are **not evaluated**. A silent BM25 fallback is not semantic evidence.

This report does not claim that results on eight species generalize to a larger catalogue.

## Reproduction context and immutable inputs

* Catalogue: `caribbean`, pack version 3, schema version 1, 8 species; search-document schema version 1.
* `PackManifest.json`: SHA-256 `2fb736bd8b2b4a6d77ef91064c0628a2eb64ad87d30a567c871ed487b532a954`.
* `Creatures.json`: SHA-256 `276bbc8ff27071d7c06662c3dc603668221994533711a8b2f5bc738c6ff6c708`.
* Main benchmark v1: SHA-256 `cb5f4adcd312204c6adfe6ce8e3fcfb6a126005dec120d9f0d56550d19087bea`.
* Limited fixture v1: SHA-256 `a1cb92494b086e0aa7243ed9ef853a68a4a9dc91444f2a1acf4e6a4b41e2fda6`.
* Record the final evaluation Git SHA with any archived run.

There is nothing to record for model source/revision/license, conversion settings, or model/tokenizer/index checksums: **no encoder has been selected**. Generated artifacts remain ignored under `Tools/SemanticSearch/generated/`; none were committed.

## Encoder screening status

No model comparison was executed: the environment contains neither frozen models nor Core ML conversion/device execution. Candidate families for development-only screening are `sentence-transformers/all-MiniLM-L6-v2`, `intfloat/e5-small-v2`, and `BAAI/bge-small-en-v1.5`. Capture their model cards, exact file licenses, tokenizer support, operations, sizes, and redistribution terms at immutable upstream revisions before use. A name or advertised license alone is not legal/offline-deployment verification. Do not download at app runtime.

## Available identical-case measurements

Linux desktop command (Swift 6.1.3):

```sh
swift test --filter IdentificationBenchmarkTests.testDevelopmentQualityGatesForStructuredAndHybrid
```

Both engines used the same 70 development cases (56 positive, 14 no-match) through `LocalMarineLifeIdentificationService`:

| Engine | Retrieval recall | Top-1 | Top-3 | Top-10 | Correct no-match | False positives | Gate |
|---|---:|---:|---:|---:|---:|---:|---|
| Structured | 56/56 | 38/56 | 42/56 | 45/56 | 14/14 | 0/14 | pass v1 development floor |
| BM25-50 + hybrid | 56/56 | 43/56 | 44/56 | 45/56 | 14/14 | 0/14 | pass v1 development floor |
| Real semantic + hybrid | not evaluated | not evaluated | not evaluated | not evaluated | not evaluated | not evaluated | **not evaluated** |

Semantic provider accounting: requests **0**, genuine successes **0**, fallbacks **0**. No semantic run was attempted because artifacts were absent; this is not a successful zero-fallback run. Limited-case behavior, confidence caps, per-species results, and query-type regressions with a genuine model are not evaluated.

The existing 100-case fixture has already been inspected and measured in previous work, so its nominal 30-case holdout is regression data. It was not rerun here. Fresh unseen, independently authored cases are required for independent validation.

## Frozen gates for the future measured run

Benchmark v1 thresholds in `CandidateRetrievalBenchmark.md` remain unchanged. Before opening fresh holdout, archive a completed manifest with exact model revision/license, tokenizer/preprocessing, conversion precision/quantization, catalogue fingerprint/index, ranking values, datasets, checksums, and acceptance criteria. Run holdout once and do not tune against failures.

Parity must first use development examples. The example manifest contains initial mechanical tolerances (maximum component error 0.001, minimum cosine 0.999, zero top-10 changes); justify and freeze these from development evidence rather than relaxing them after holdout.

Freeze device budgets before final measurement. Proposed budgets for the oldest actually supported iPhone class are: cold initialization ≤2,000 ms; first query after load ≤1,000 ms; warm median ≤250 ms; warm p95 ≤500 ms; peak incremental memory ≤200 MiB; packaged semantic assets ≤100 MiB; cached repeat ≤100 ms; cancellation observed ≤250 ms; no main-thread stall >100 ms; and identical identification with networking disabled. Newer devices should meet the same limits. These are unmeasured proposals.

## Gate ledger

| Required gate | Decision | Evidence / blocker |
|---|---|---|
| Provenance and redistribution | **not evaluated** | no selected artifact/revision/license |
| Matching tokenizer/preprocessing/index | **not evaluated** | bundle absent |
| Reference ↔ Core ML parity and ranking changes | **not evaluated** | conversion/device vectors absent |
| Structured development | **pass** | 70 cases; table above |
| BM25 hybrid development | **pass** | 70 cases; table above |
| Semantic retrieval recall / final quality | **not evaluated** | zero genuine runs |
| Limited descriptions / confidence caps | **not evaluated** | genuine provider unavailable |
| Fresh one-shot holdout | **not evaluated** | fresh unseen fixture unavailable |
| Physical and oldest-device performance | **not evaluated** | hardware unavailable |
| Cache, cancellation, responsiveness, offline | **not evaluated** | artifact/device unavailable |

Simulator evidence: none. macOS Core ML evidence: none. Physical-device evidence: none. Desktop Linux evidence covers only the two non-semantic baselines.

## Smallest follow-up

Select and legally approve one encoder on development data; freeze one completed manifest and genuine source/Core ML/index artifacts; run parity; then run the packaged pipeline on the oldest supported and one current physical iPhone with networking disabled. If development/device gates pass, obtain a fresh representative catalogue-scale holdout and run it once. Promote only if every required gate passes with zero silent fallbacks and the evidence supports the intended catalogue scale.
