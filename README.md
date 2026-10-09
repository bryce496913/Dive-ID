# Dive ID — v0.5 candidate

An iPhone prototype for offline written-description search, region selection,
results/species details, and persistent saved identifications. Requires **iOS 18+**.
The candidate uses marketing version **0.5**, build **2**. Build 2 exceeds the
previous repository build (1); TestFlight/App Store Connect distribution history
is unavailable and must be checked before any future distribution. Nothing is
submitted or published by this repository workflow.

## Current catalogue and availability

| Pack | Version | Bundled records | Human-reviewed | Publication-eligible |
| --- | ---: | ---: | ---: | ---: |
| Caribbean | 3 | 8 | 0 | 0 |
| Tropical Pacific | 2 | 384 | 0 | 0 |

All 392 records remain draft. Debug explicitly permits the full development
catalogue. Release uses only publication-eligible records: **Release currently has
no searchable regions or species**. Its UI disables new searches and preserves
access to saved identifications. Do not add `DEBUG` to Release, promote synthetic
fixtures, or treat search quality as human publication approval.

The production engine is **BM25 retrieval plus biological ranking**, with at most
50 retrieved candidates and ten displayed matches. Scores describe relative clue
similarity, not calibrated probabilities or confirmed identifications. Catalogue
coverage is incomplete; source transcriptions and some biological fields still
need review. See [source review](Docs/CataloguePublicationReview.md).

## Features and limits

- Description search and bundled catalogue access work without a network or account.
- Region selection chooses an available local pack; there are no pack downloads.
- Results/details retain their temporary session during detail/back navigation;
  finished flows release it. Remaining temporary sessions have a hard limit of 16.
- Saved sightings use persistent JSON storage and include a species snapshot.
  Initialization/write failures expose an error and retry path, never a silent
  memory-only success. Unreadable storage is not automatically reset.
- **Photo identification is unavailable.** The home action is disabled and says
  “Coming later”; image preparation code is not an identification model.
- **Core ML search is experimental**, Debug-only opt-in pending real-model
  evaluation. The default remains BM25. Debug diagnostics distinguish requested
  and actual engines and label a BM25 fallback explicitly.
- Artwork is a placeholder, not a verified species photograph. Caribbean SVG
  marker metadata is bundled, but the current iOS UI does not render those files.

## Build an iPhone app

Open **`DiveID.xcodeproj`**, select the shared **DiveID** scheme and an iOS 18+
iPhone simulator or connected iPhone. Physical installation needs an authorized
development team and provisioning. CI currently selects Xcode 16.4.

```sh
open DiveID.xcodeproj
xcodebuild -project DiveID.xcodeproj -scheme DiveID -showdestinations
```

Do not open `Package.swift` expecting an app destination. SwiftPM builds the
portable core and test resources, including the catalogues; it excludes the
SwiftUI application entry point and feature views. A successful SwiftPM build
is not evidence that the iOS app was built, installed or exercised.

See [candidate validation](Docs/V05CandidateValidation.md) for exact simulator,
Release and device checks, independent test stages, and an iPhone measurement
worksheet. No actual iPhone latency or memory measurement is currently available.

## Required portable checks

```sh
python3 -m pip install -r Tools/TropicalPacificWorkbook/requirements.txt \
  -r Tools/CatalogImport/requirements.txt
suite_failures=0
for suite in TropicalPacificWorkbook CatalogImport CatalogReview SemanticSearch/tests CI Evaluation; do
  python3 -m unittest discover -s "Tools/$suite" -p 'test_*.py' -v || suite_failures=1
done
test "$suite_failures" = 0
swift test
swift test -c release
python3 Tools/Evaluation/run_v05.py --configuration debug
```

CI runs Python, Linux/macOS SwiftPM and hosted Xcode validation independently and
requires every job to succeed. The v0.5 evaluation currently exposes failures;
these commands must retain their nonzero exit status. The shell loop runs all six suites and aggregates their status. Existing Caribbean/Pacific gates pass, but the new source-informed
46-case development evaluation fails on paraphrase retrieval/ranking, freshwater
false positives and regional conflicts. See [full results and limitations](Docs/V05DevelopmentEvaluation.md).
Its descriptions are synthetic, not independent diver holdout data. The legacy
100-case benchmark includes an opt-in frozen cohort; routine tests leave it closed.

## Rebuild catalogue data

```sh
python3 Tools/CatalogReview/regenerate_caribbean.py
python3 Tools/CatalogImport/import_tropical_pacific.py
python3 Tools/CatalogReview/prepare_source_review_pass.py
python3 Tools/CatalogReview/prepare_review_batch.py
python3 Tools/CatalogReview/verify_source_review_reproducibility.py
```

Use the validated overlay/import inputs rather than editing generated records.
Stable IDs, original provenance and named human review decisions must survive
regeneration. See [Pacific import documentation](Docs/TropicalPacificCatalogue.md)
and [candidate readiness record](Reports/V05CandidateReadiness.json). Publication
approval and on-device readiness are separate from import/build success.
