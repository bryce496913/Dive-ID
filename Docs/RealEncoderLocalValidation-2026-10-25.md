# Real encoder: local conversion, parity and end-to-end execution (2026-10-25)

Run on a Mac with Xcode, after the conversion repair in `dfe79f0` and the fingerprint
fix in `b138001`. Semantic search stays experimental: Release and Internal keep BM25,
and nothing here promotes the model.

## Environment

macOS 26.5 (25F71), Xcode 26.5 (17F42), Apple silicon. Conversion environment
(hash-locked, `Tools/SemanticSearch/requirements-real-encoder.txt`): Python 3.12.15,
NumPy 2.3.5, PyTorch 2.5.0, transformers 4.51.3, coremltools 8.3.0. Source model
`sentence-transformers/all-MiniLM-L6-v2` at revision
`c9745ed1d9f207416be6d2e6f8de32d1f16199bf`.

## Conversion root cause, confirmed on this Mac

The real model fails in coremltools' `_int` → `_cast` with the CI error
`TypeError: only 0-dimensional arrays can be converted to Python scalars`, on the traced
`aten::Int` of BERT's length-1 position slice. Changing one factor at a time:

| NumPy | PyTorch | coremltools | Real model |
| --- | --- | --- | --- |
| 2.5.4 (what the unpinned install resolved) | 2.6.0 | 8.3.0 | fails |
| 2.4.4 | 2.6.0 | 8.3.0 | fails |
| 2.3.5 | 2.6.0 | 8.3.0 | converts |
| 2.4.4 | 2.5.0 | 8.3.0 | fails |
| 2.3.5 | 2.5.0 | 8.3.0 | converts (the locked set) |

NumPy 2.4 turned the deprecated `int(ndarray)` on a one-element array into an error;
PyTorch does not matter, and the traced graph is the standard one. The pins and the
real-conversion regression test from `dfe79f0` stand.

## Genuine artifacts

The full provisioning flow ran locally: download, conversion, compilation, index
generation for 4,798 Global records, and transactional packaging. Identities from
`provisioning-evidence.json`:

| Artifact | SHA-256 / fingerprint |
| --- | --- |
| Compiled model | `fe550f1e1edf5e4d11e9bc27a4743e9815abd5e8130cfb7b03803842dd344c30` |
| Source `.mlpackage` | `b581fdb492569b6be7b9fd1ef61e993fe561cf73963302dfdb9aac90af80f139` |
| Vocabulary | `373b066fa218cddd79eec036c10bec16e439381f94d6845bf3106ef8194cff36` |
| Tokenizer fingerprint | `36a45acf1a78ce0cf87b5d3dc723518e733a02ce42b733b96d6e9463738eaa01` |
| Contract | `ed4ddd8a97675577c0a395fdb53e2ca5630600d5250e7da6667c3a7f16dd2d4b` |
| Corpus | `599d8a1b9f69020120c0b2930481bd9c07568e677b56efe2972bba9d9c3f9ec6` |
| Index | `f02297d6a8e0c83129aabdfbd1e9c33457c2c5cc520ebb1480ebc342b19d5275` |
| Parity spec | `121015b818ac76ed03d4fb22e9798585aee6cc95c84b759679aece22d6706014` |

`validate_production_readiness.py` accepted the evidence against the resources packaged
in the hosted app bundle (schema valid, no errors, `productionSemanticApproved: false`).

## Parity (tolerances frozen in `fb0cfbb`, before any genuine vector existed)

Tolerances: cosine ≥ 0.999, largest element difference ≤ 0.01, unit norm within 1e-4,
padding invariance ≥ 0.99999, retrieval top-10 overlap ≥ 9, score difference ≤ 0.02, and
the same top-1 when the reference margin is at least 0.01. Ten probes cover punctuation,
accents, whitespace controls, a nearly all-padding input and one past the 256-token
truncation point, so tokenizer truncation and padding are exercised.

| Where | Minimum cosine | Max difference | Top-10 overlap | Top-1 agreement |
| --- | --- | --- | --- | --- |
| Provisioning (Python reference vs Core ML) | 0.99997 | 0.00128 | 10/10 | 10/10 |
| SwiftPM app code, macOS | 0.99997 | 0.00128 | 10/10 | 10/10 |
| Hosted app, iPhone 17 Pro simulator, iOS 26.5 | 0.99999 | 0.00093 | 10/10 | 10/10 |

On macOS, Core ML could not compile the model for the Neural Engine (`ANECCompile()
FAILED`) and ran it on CPU/GPU; it is still the Core ML engine.

## Actual-engine evidence

| Run | Requested | Actual | Fallbacks |
| --- | --- | --- | --- |
| SwiftPM evaluation, 116 Global cases | Core ML semantic | Core ML semantic, 116/116 | 0 |
| Hosted app (`testBundledArtifactsServeTheExperimentalSelection`) | experimentalCoreML | experimentalCoreML | none |
| Physical iPhone 14 Pro, Debug, 3 cases | Core ML semantic + BM25 | Core ML semantic + BM25 | none |

**Simulator fix.** The hosted test first fell back with "invalid model output": the
iOS 26.5 simulator's Core ML has no MPSGraph engine but still took the GPU path with
all compute units and produced non-finite vectors. The app correctly failed closed. The
simulator now loads the model CPU-only (`#if targetEnvironment(simulator)` in
`CoreMLSemanticEmbeddingProvider`); devices and macOS are unchanged. CI's iOS 18
simulator was not available locally.

## Experimental admission against BM25 (same 116 cases, same 4,798-record catalogue)

No threshold was tuned; the 0.30 admission cosine is unchanged and remains provisional.

| Kind | Cases | Expected top-1 BM25 | Expected top-1 merged | Abstained BM25 | Abstained merged | Unexpected semantic-only results |
| --- | --- | --- | --- | --- | --- | --- |
| identification | 90 | 52 | 48 | 8 | 1 | 143 |
| ambiguous | 2 | 0 | 0 | 0 | 0 | 1 |
| regionConflict | 4 | 0 | 0 | 0 | 0 | 3 |
| noMatch | 20 | 0 | 0 | 20 | 20 | 0 |

- Merging **lowers** expected top-1 from 52 to 48 and changes the top result in 12 cases.
- It answers 7 cases BM25 abstained on and abstains on none that BM25 answered; only one
  case gains its expected species solely from semantic retrieval.
- It adds 147 semantic-only results that are not the expected species, shown at up to
  0.76 confidence. No no-match case gained results.
- Raw cosine: expected-species median 0.54 (minimum 0.12); no-match top-1 median 0.34,
  maximum 0.52; background 99th-percentile median 0.50. At 0.30 the threshold does not
  separate no-match descriptions from matches, so it cannot be the gate on its own.
- macOS Debug SwiftPM: embedding median 13 ms, scoring median 530 ms, first load 2.0 s.
  On the iPhone the first experimental search took 13.5 s and later ones 1.2–1.7 s.

The candidate is not ready for admission. Any calibration should use the development
descriptions only and be frozen before an independent held-out evaluation.

## Tests run for this commit

- SwiftPM `SemanticEndToEndTests` on the real artifacts: parity, merge and distribution
  passed; the bundled-artifact test skips under SwiftPM by design (it is the hosted test).
- Hosted simulator, `DIVEID_REQUIRE_SEMANTIC=1`: both semantic tests passed after the
  simulator fix (they failed before it, as described).
- Physical-device results: `DeviceValidation-2026-10-25.md`.
- Full hosted unit-test target, iPhone 17 Pro simulator iOS 26.5, serial: 313 executed,
  11 skipped (opt-in external, custodian and semantic tests), 0 failures.
- Hosted UI tests on iPhone 17 Pro and iPhone SE simulators: see the largest-text section
  of `DeviceValidation-2026-10-25.md` (one unexplained SE smoke failure remains).
- Python: `Tools/CI` tests and `Tools/Evaluation/test_independent_divers.py` pass.
