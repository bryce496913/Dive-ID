# Semantic-search corpus exporter

## Production-readiness gate

The frozen 100-case Caribbean benchmark remains a **regression gate**, not a production
claim. `production-readiness.v1.json` is the separate production evaluation ledger. It
currently records `production status = not evaluated`: there is no genuinely unseen,
human-reviewed description set, representative reviewed catalogue, or genuine encoder
run in this checkout. Null thresholds are intentional rather than invented targets.

Validate the ledger, or fail closed when a release process requires approval:

```sh
python3 Tools/SemanticSearch/validate_production_readiness.py \
  Tools/SemanticSearch/production-readiness.v1.json
python3 Tools/SemanticSearch/validate_production_readiness.py --require-approved \
  Tools/SemanticSearch/production-readiness.v1.json
```

Approval binds all seven identities named in the request: model revision, tokenizer,
preprocessing, embedding index, ranking contract, catalogue, and fresh dataset. A change
to any identity invalidates approval. All three engines must pass the same fresh evaluation.
Fresh descriptions are holdout-only and may never automatically flow into corpus export,
training, synonyms, ranking/threshold tuning, or debugging. Recall@k and top-k are marked
non-informative when the catalogue has fewer than k records.

This developer-only Python tool exports an app-loadable identification pack to compact,
deterministic JSONL. Python is **not** an iOS runtime dependency.

```sh
python3 Tools/SemanticSearch/export_search_corpus.py
```

The default input is the bundled Caribbean `PackManifest.json` and `Creatures.json`; the
default output is ignored under `Tools/SemanticSearch/generated/`. Pass `--pack` and
`--output` to use another app-loadable pack. Invalid records are listed and the export
fails atomically rather than filling in or silently repairing biological data.

## JSONL schema

Each line contains:

- exact `species_id`, `pack_id`, and `pack_version` values;
- `common_name` and `scientific_name`;
- `search_text` and the identity, appearance, habitat, behavior, range, life-stage,
  and general `search_sections`, built with the same ordering, normalization, and
  source fields as `SpeciesSearchDocument`;
- selected source-backed `structured` fields for analysis;
- `document_schema_version` and SHA-256 `document_fingerprint`;
- the unmodified `review` object, `review_status`, derived `provenance_tier`, and
  `human_review_required` flag.

`verified` maps to `production/reviewed`. Other current records remain `draft` and
require human review; a future explicit `humanReviewRequired: true` maps to
`human-review-required`. This makes trust visible without promoting draft material.
The Tropical Pacific staging workbook is intentionally unsupported by this pass.

## Leakage boundary and model-development sequence

The exporter reads only catalogue pack files. It does not read benchmark cases or emit
query/species training pairs. In particular, neither the 100-case Caribbean evaluation
benchmark nor its 30-case `holdout` descriptions may be supplied to training or corpus
generation. Make model and tuning decisions using development evidence; inspect holdout
results **only after** those decisions are fixed.

Development proceeds in this order:

```text
Catalogue
→ Search documents
→ Corpus export
→ Embedding-model experiments
→ Core ML conversion
→ Precompute species vectors
→ Benchmark
→ Only then integrate model into app
```

The next phase should select compact encoders outside the app, compare them without
holdout leakage, then convert the chosen encoder to Core ML and generate an index whose
metadata matches `SpeciesEmbeddingIndexMetadata`. Do not commit generated corpora,
models, or full embedding indexes.

## Experimental Core ML artifact contract

No production encoder is bundled or promoted by this change. A developer may package a
locally licensed, genuine encoder by adding these four build resources (replace `PACK`):

* `Semantic-PACK.contract.json` — `SemanticModelArtifactContract` encoded with Swift's
  default camel-case JSON keys;
* `Semantic-PACK.mlmodelc` — a compiled Core ML model;
* `Semantic-PACK.vocab.json` — a JSON token-to-integer WordPiece vocabulary;
* `Semantic-PACK.index.json` — the generated `SpeciesEmbeddingIndex`.

The version-1 contract must name the model inputs (`inputIDsFeature`,
`attentionMaskFeature`, and optional `tokenTypeIDsFeature`) and output
(`outputFeature`). Inputs are int32 `[1, maximumSequenceLength]`. The only supported
output shapes are exactly `[1, embeddingDimension]` for `modelOutput`, or
`[1, maximumSequenceLength, embeddingDimension]` token states for `cls`/`meanMasked`.
Outputs must be Float32 or Float16. Shape and type are checked from model metadata at
load time; runtime pooling uses dimension-aware `MLMultiArray` indexing and never
infers layout from flattened element count.
It must also specify model/version, tokenizer/preprocessing identities, special-token
strings, lowercasing/accent behavior, sequence limit, beginning/end truncation, query
and document prefixes, pooling, and `normalizeL2: true`. The Core ML conversion and
index build must use the same hidden-state ordering and numerical weights. Unsupported
tokenizer normalization must be resolved during conversion rather than approximated.

Generate canonical documents, then build an index entirely from a local model directory:

```sh
python3 Tools/SemanticSearch/export_search_corpus.py \
  --output Tools/SemanticSearch/generated/caribbean-search-corpus.jsonl
python3 Tools/SemanticSearch/build_embedding_index.py \
  --corpus Tools/SemanticSearch/generated/caribbean-search-corpus.jsonl \
  --contract /path/to/Semantic-caribbean.contract.json \
  --model /path/to/local-hugging-face-model \
  --output Tools/SemanticSearch/generated/Semantic-caribbean.index.json
```

The second command validates the local Hugging Face tokenizer as WordPiece and proves
its vocabulary, special tokens, inspected lowercase/accent behavior, maximum length,
and explicitly configured truncation side match the contract. It then bypasses Hugging
Face preprocessing: a small Python tokenizer mirroring Swift emits the exact padded IDs
and masks. The index records canonical vocabulary and tokenizer-contract SHA-256
fingerprints. Developer-only `torch` and `transformers` are loaded with
`local_files_only=True`; they are not app or identification dependencies. Copy local
artifacts into the target only for a private build. Generated corpora, model bundles,
and full indexes remain ignored and must not be committed. Small synthetic vocabularies,
contracts, and indexes may be committed only as test fixtures and do not demonstrate
model quality or identification accuracy.

Enable the engine explicitly in a developer build by setting the user default
`DiveIDExperimentalSemanticSearch=true`. Default installs remain on BM25. Missing,
stale, or malformed artifacts emit a typed diagnostic and fall back offline; query text
is excluded from the metrics payload. Device inference, latency, encoder conversion
parity, and accuracy remain unverified until a compatible real artifact is supplied.

## Frozen-candidate audit

`evaluate_candidate.py` is the evidence collector for the next real-model run. It does
not generate or substitute embeddings. Before exposing holdout cases, copy
`candidate-manifest.example.json` outside the repository, fill every field, pin the
model to an immutable hexadecimal revision, declare conversion input/output tensors,
freeze the complete preprocessing and ranking contracts, identify every dataset and
catalogue by fingerprint, list at least one uniquely pathed artifact with its SHA-256
and role, and make it read-only. Empty evidence sections are invalid, and `frozenAtUTC`
must be a valid UTC `Z` timestamp.

Reference and physical-device runners export JSONL rows shaped as
`{"id":"case-id","vector":[...]}`; catalogue rows use species IDs. Verify the
frozen files and parity with:

```sh
python3 Tools/SemanticSearch/evaluate_candidate.py \
  --manifest /frozen/candidate-manifest.json --root /frozen \
  --reference /frozen/reference-query-vectors.jsonl \
  --coreml /frozen/device-query-vectors.jsonl \
  --catalogue-vectors /frozen/reference-catalogue-vectors.jsonl \
  --output /frozen/parity-report.json
```

Core ML output must come from the packaged model on named physical hardware. The command
exits 1 for checksum/parity failure, 2 for invalid evidence, and 0 only when verification
passes. Omitting all vector inputs is an artifact preflight and reports parity as
`not-evaluated`; partial parity inputs are rejected.
