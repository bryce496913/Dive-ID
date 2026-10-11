# Enrichment / semantic comparison preflight — 2026-10-11 UTC

**Blocked; production stays BM25 with biological ranking.** No independent descriptions
or frozen baseline have been supplied since the preparation pass. No development
failure can therefore be assigned a source/parsing/retrieval/ranking/presentation cause
in this experiment. No enrichment batch was selected, no source correction claimed,
and no ID, provenance, review status, frozen case or ranking parameter changed.

Inspected candidate: main `dce8db317736caff2d425e1d347a1ca850e035f6`, tree
`d7dffb27c2bd4829335aa91a9a0b829cb00db37a` (PR #96 merged). Local starting
commit `d5771aa` has the same tree. No applicable AGENTS.md was found. New branch:
`codex/enrichment-semantic-preflight`. This PR only adds preparation and evidence records.

## Identities and outcomes

Exact catalogue/manifest SHA-256 values, encoder lock hash and aggregate regression
counts are in EnrichmentSemanticPreflight.json. Original catalogue: 8 Caribbean +
384 Pacific records, all draft; publication-eligible count **0**. Enriched catalogue:
**not created**. Independent dataset identity/baseline: **not supplied**.

| Measurement | Result |
| --- | --- |
| Original BM25, independent data | Unexecuted; no independent cases/baseline |
| Enriched BM25, same independent cases | Unexecuted; no justified enrichment |
| Genuine semantic vs BM25, same enriched catalogue | Unexecuted; missing dataset, artifacts and Apple runtime |
| Existing synthetic v0.5 v2 development regression, original catalogue | Recall 34/34; top-1 27/34; top-3 32/34; top-10 34/34 |
| Synthetic policy regression | Correct no-match 6/6, false positives 0/6; ambiguity 2/2; region conflict 4/4; confidence compliant 46/46 |
| Synthetic publication evaluation | All 46 cases coverage-blocked; no quality denominator |

There are zero unchanged-fixture acceptance failures. These synthetic cases have
influenced implementation and are not independent evidence or a before/after enrichment
comparison. No new holdout was opened. Existing scores do not justify catalogue expansion.
The eight-record Caribbean pack also saturates candidate recall at a limit of 50.

## Encoder and environment evidence

Frozen candidate: `sentence-transformers/all-MiniLM-L6-v2` revision
`c9745ed1d9f207416be6d2e6f8de32d1f16199bf`; lock hash
`3e3d212c588ece68371be9f34580bdb2c8de5ba74a7ec4bfd9d70f6e604acf2b`.
Inspected generated directory contains only an old text corpus; no genuine model,
tokenizer, index or provisioning evidence exists there. Packaged
`DiveID/Resources/SemanticSearch` is absent. The frozen recipe is inspectable but actual
model/tokenizer/preprocessing/index identity and Core ML parity remain unverified.

This executor is Linux; `xcodebuild` is absent and no Apple hardware is attached.
A HEAD request for the pinned Hugging Face config failed with curl exit 7, unable to
connect to proxy:8080. The current failure is not the historical report's HTTP 403.
No alternate download source or synthetic artifact was substituted.

Real semantic requests **0**, genuine executions **0**, semantic fallbacks **0**:
no semantic experiment ran. Synthetic-provider unit tests are not genuine inference.
Offline latency, memory, package size and cancellation: **unexecuted on both simulator
and physical iPhone**. Production ledger validation passes its schema with
`productionSemanticApproved: false`; it does not approve this candidate.

## Available validation

- Swift 6.2.3/Linux full suite: 129 tests, 3 expected skips, zero failures; includes
  Pacific/Caribbean quality gates, semantic/fallback contracts and frozen v0.5 gates.
- Explicit v0.5 service evaluation: exit 0, 46 synthetic cases on each development
  engine; publication fully blocked. Frozen fixture SHA is in the JSON report.
- Semantic Python tooling: 33 tests passed.
- Evaluation Python tooling: 9 tests passed.
- Production-readiness validator: valid schema, not approved.

Reproduce portable checks with `swift test --jobs 4`,
`python3 -m unittest discover -s Tools/SemanticSearch/tests -p 'test_*.py'`,
`python3 -m unittest discover -s Tools/Evaluation -p 'test_*.py'`, and
`python3 Tools/Evaluation/run_v05.py --output /tmp/v05.json --log /tmp/v05.log`.
Use the available Swift 6 toolchain and a writable SwiftPM/module cache on this executor.

## Smallest evidence-based next step

Obtain the custodian-approved development export plus original frozen baseline and
catalogue; keep holdout private. Classify actual failures, then inspect authoritative
sources for at most five existing records. Follow Docs/EnrichmentSemanticComparison.md
for source evidence/fingerprints/re-review, original→enriched BM25 isolation, artifact
provisioning and genuine same-service encoder comparison. Real Core ML service-run
collection still needs an adapter once artifacts are available; the current vector audit
is not that runner. Start with the provisioner's bounded Caribbean pack, explicitly
reporting small-pack saturation, before considering any wider supported regional index.
No expansion, promotion or distribution is justified by this preflight.
