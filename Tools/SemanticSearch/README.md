# Semantic-search corpus exporter

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
