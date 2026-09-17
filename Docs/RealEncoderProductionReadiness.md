# Real encoder production-readiness evaluation — 2026-09-16

## Decision

**Provisioning blocked; do not promote.** The production default remains BM25. This pass selected and froze a genuine encoder and added one-command, checksum-producing conversion and packaging, but the execution environment denied access to Hugging Face (`CONNECT tunnel failed, HTTP 403`) and is Linux without Core ML/Xcode. Consequently the pretrained bytes could not be retrieved here, and genuine inference, Core ML parity, semantic benchmark results, and Apple runtime measurements remain **not evaluated**. Infrastructure output and BM25 fallback are not semantic evidence.

This report does not claim that results on eight species generalize to a larger catalogue.

## Reproduction context and immutable inputs

* Catalogue: `caribbean`, pack version 3, schema version 1, 8 species; search-document schema version 1.
* `PackManifest.json`: SHA-256 `2fb736bd8b2b4a6d77ef91064c0628a2eb64ad87d30a567c871ed487b532a954`.
* `Creatures.json`: SHA-256 `276bbc8ff27071d7c06662c3dc603668221994533711a8b2f5bc738c6ff6c708`.
* Main benchmark v1: SHA-256 `cb5f4adcd312204c6adfe6ce8e3fcfb6a126005dec120d9f0d56550d19087bea`.
* Limited fixture v1: SHA-256 `a1cb92494b086e0aa7243ed9ef853a68a4a9dc91444f2a1acf4e6a4b41e2fda6`.
* Canonical corpus: SHA-256 `9a589f77f1b6be547d29d14a87fef9b21c617a7159cd644eafee2d5e611ea3d4`; catalogue fingerprint `335468d199be540e833ab80b7c0680c2dc782505cb8ae6377a60a3f5958a7168`; exactly the eight stable IDs in the bundled pack.
* Record the final evaluation Git SHA with any archived run.

Selected model: `sentence-transformers/all-MiniLM-L6-v2` at immutable source revision `c9745ed1d9f207416be6d2e6f8de32d1f16199bf`, Apache-2.0. Required upstream files include `config.json`, `model.safetensors`, `tokenizer.json`, `tokenizer_config.json`, `special_tokens_map.json`, `vocab.txt`, and `1_Pooling/config.json`; the complete Apache-2.0 text is tracked under `Tools/SemanticSearch/licenses`. The lock file SHA-256 is `3e3d212c588ece68371be9f34580bdb2c8de5ba74a7ec4bfd9d70f6e604acf2b`.

The frozen recipe is 384 dimensions, 256 tokens, right truncation, uncased accent-stripping WordPiece with `[CLS]`/`[SEP]`, attention masks, masked-mean pooling, and L2 normalization. Queries and documents use identical preprocessing and no prefix. Conversion is an iOS 18 ML Program with Float16 compute and a `[1,256,384]` hidden-state output; the app performs the same masked mean and normalization. The model is practical because its six-layer architecture is substantially smaller than base BERT-class encoders, it has an established sentence-similarity recipe, and all operations are supported by the pinned TorchScript → Core ML route. No catalogue or benchmark case is used for training.

Generated artifacts remain ignored under `Tools/SemanticSearch/generated/`; none were fabricated or committed. The provisioner records SHA-256 and byte length for every actual upstream and derived artifact. Because upstream bytes were inaccessible, claiming their checksums in this report would be false.

## Encoder and execution status

MiniLM was selected over the previously listed E5 and BGE candidates for the smallest straightforward six-layer integration, symmetric no-prefix sentence encoding, reproducible BERT WordPiece tokenizer, and Apache-2.0 terms. This is an engineering choice pending legal notice review, not distribution approval. The app performs no runtime download.

Attempted retrieval on Linux x86_64 with `curl -I -L https://huggingface.co/api/models/sentence-transformers/all-MiniLM-L6-v2` failed at the environment proxy with HTTP 403. Python had no cached model, `torch`, `transformers`, `coremltools`, or `huggingface_hub`; no Apple runtime was present. Therefore the requested reference/Core ML comparison and complete experimental app path could not honestly execute in this environment.

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

Semantic provider accounting: requested **0**, actual semantic **0**, genuine successes **0**, fallbacks **0**. No semantic benchmark was attempted because pretrained artifacts were unavailable; this is not a successful zero-fallback run. Actual-engine identity, semantic candidate recall, top-1/top-3/top-10, limited-case behavior, confidence caps, and semantic regressions are not evaluated.

The existing 100-case fixture has already been inspected and measured in previous work, so its nominal 30-case holdout is regression data. It was not rerun here. Fresh unseen, independently authored cases are required for independent validation.

## CI evidence

The inspected checkout began at commit `ffb9a25` (merge of PR #55). The GitHub CLI was
not authenticated, and the unauthenticated GitHub Actions API returned no readable
response for this repository, so no run URL or unit/UI job result was accessible. The
workflow's execution for that SHA is therefore **unverified**, not failed. Locally,
portable Swift and Python tests passed as recorded below; Xcode unit and UI targets
could not execute on Linux. This pass intentionally does not redesign CI.

## Frozen gates for the future measured run

Benchmark v1 thresholds in `CandidateRetrievalBenchmark.md` remain unchanged. Before opening fresh holdout, archive a completed manifest with exact model revision/license, tokenizer/preprocessing, conversion precision/quantization, catalogue fingerprint/index, ranking values, datasets, checksums, and acceptance criteria. Run holdout once and do not tune against failures.

Parity must first use development examples. The example manifest contains initial mechanical tolerances (maximum component error 0.001, minimum cosine 0.999, zero top-10 changes); justify and freeze these from development evidence rather than relaxing them after holdout.

Freeze device budgets before final measurement. Proposed budgets for the oldest actually supported iPhone class are: cold initialization ≤2,000 ms; first query after load ≤1,000 ms; warm median ≤250 ms; warm p95 ≤500 ms; peak incremental memory ≤200 MiB; packaged semantic assets ≤100 MiB; cached repeat ≤100 ms; cancellation observed ≤250 ms; no main-thread stall >100 ms; and identical identification with networking disabled. Newer devices should meet the same limits. These are unmeasured proposals.

## Gate ledger

| Required gate | Decision | Evidence / blocker |
|---|---|---|
| Provenance and redistribution | **partial** | model/revision/Apache-2.0 frozen; actual license bytes and legal approval await provisioning |
| Matching tokenizer/preprocessing/index | **partial** | exact shared recipe and parity gate implemented; source bytes/index unavailable |
| Reference ↔ Core ML parity and ranking changes | **not evaluated** | conversion/device vectors absent |
| Structured development | **pass** | 70 cases; table above |
| BM25 hybrid development | **pass** | 70 cases; table above |
| Semantic retrieval recall / final quality | **not evaluated** | zero genuine runs; no semantic denominator reported |
| Limited descriptions / confidence caps | **not evaluated** | genuine provider unavailable |
| Fresh one-shot holdout | **not evaluated** | fresh unseen fixture unavailable |
| Physical and oldest-device performance | **not evaluated** | hardware unavailable |
| Cache, cancellation, responsiveness, offline | **not evaluated** | artifact/device unavailable |

Simulator evidence: none. macOS Core ML evidence: none. Physical-device evidence: none. Linux evidence covers corpus identity, portable tests, and the two non-semantic baselines only. Packaged asset size, cold initialization, first query, warm median/p95, memory, cancellation, and networking-disabled behavior are all unmeasured.

## Smallest follow-up

Run the documented provisioner on a networked Xcode 16.4 Mac, archive its checksum manifest, then define parity tolerances **before** running comparison (the existing maximum absolute error 0.001, minimum cosine 0.999, zero top-10 changes remain unchanged). Run the packaged pipeline on the simulator for integration and on the oldest supported plus one current physical iPhone with networking disabled. Only if genuine execution, development quality, parity, cancellation, and performance gates pass should this encoder be evaluated against a larger reviewed catalogue. The present blocked run alone does not merit that larger evaluation.
