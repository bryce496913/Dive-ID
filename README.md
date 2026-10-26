# Dive ID — v0.5 candidate

An iPhone prototype for offline written-description search, region selection,
results/species details, and persistent saved identifications. Requires **iOS 18+**.
The candidate uses marketing version **0.5**, build **2**. Build 2 exceeds the
previous repository build (1); TestFlight/App Store Connect distribution history
is unavailable and must be checked before any future distribution. Nothing is
submitted or published by this repository workflow.

## Current catalogue and availability

| Pack | Version | Bundled records | Human-reviewed | Publication-eligible | V05 gates (development, top10) |
| --- | ---: | ---: | ---: | ---: | --- |
| Caribbean | 3 | 8 | 2 | 2 | pass (16/16); retired region, development fixture only |
| Tropical Pacific (Experimental) | 3 | 1000 | 0 | 0 | pass (18/18); retired region, development fixture only |
| Global | 25 | 4798 | 4798 | 4798 | pass, opt-in (30/34; four positive cases miss the top ten) |
| Tropical Atlantic Regions | 1 | 1039 | 1039 | 1039 | drawn from Global |
| Indo-Pacific Regions | 1 | 3592 | 3592 | 3592 | drawn from Global |
| Pacific Coast Regions | 1 | 566 | 566 | 566 | drawn from Global |
| Mediterranean | 1 | 330 | 330 | 330 | drawn from Global |

**Dive regions (owner decision, 2026-10-26).** The app offers Global and four regions
drawn from it: Tropical Atlantic Regions, Indo-Pacific Regions, Pacific Coast Regions and
Mediterranean. Each region lists Global record IDs (`Members.json`), so its records,
review status and search data are Global's, unchanged; Release shows only their approved
records, and a species that occurs in several regions is in each. Membership comes from
each record's FAO areas plus FishBase's country records, which split the Eastern Central
Pacific between Hawaii/Polynesia (Indo-Pacific) and the Americas' Pacific coast
(`Tools/FishBaseIntake/derive_regions.py`; rerun it after `publish_global.py`). Species
recorded only outside all four (for example the temperate North Atlantic) are in Global
alone. Caribbean and Tropical Pacific are **retired**: no build lists them and Release
never opens them; they stay bundled as development evaluation fixtures. An install whose
stored region is retired sees "Dive region unavailable" with a one-tap suggestion
(Caribbean → Tropical Atlantic Regions, Tropical Pacific → Indo-Pacific Regions); nothing
changes until the person chooses.

**Global is the default for new installs and is available in Release** (owner decision,
2026-10-23), after every Global record was approved in batch review. Every Global record
is approved, so Release shows all 4,798. Its search quality
evidence is unchanged: its latest opt-in evaluation runs the 34 positive V05 cases against all 4,798 records
([report](Docs/GlobalPackEvaluation.md#caribbean-species-in-global-2026-10-23),
[raw results](Reports/GlobalPackEvaluation.json)):

| Global, 4,798 records | Candidate recall | First | Top three | Top ten | No-match | Confidence compliance |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| As written | 33/34 | 18/34 | 24/34 | 30/34 | 6/6 | 46/46 |

All applicable aggregate gates pass (region conflict does not apply to a single
worldwide pack). Four positive descriptions still miss the top ten:
`v05-05-paraphrase` (Red Lionfish, Caribbean), `v05-09-diagnostic` and
`v05-09-paraphrase` (Bird Wrasse, Tropical Pacific), and `v05-10-paraphrase`
(Black Triggerfish, Tropical Pacific).

> **These results are not independent evidence and not publication approval.**
> The 34 cases are development cases that influenced the implementation, not a
> holdout; independent diver testing is still needed. Passing the search gates
> approves no record; Global's records are approved by the recorded batch decisions.

The iPhone checklist is in [V05CandidateValidation.md](Docs/V05CandidateValidation.md#release-device-checklist-prepared-2026-10-22-unexecuted).

- **Caribbean:** Bryce approved Atlantic Blue Tang and Queen Angelfish on October 12, 2026.
- **Global:** Bryce approved all 20
  [current-content batches](Docs/GlobalBatchReview.md#current-content-review-2026-10-23)
  on October 23, 2026, all recorded as individually reviewed on Bryce's statement that
  he reviewed every entry (`--all-individually-reviewed`). 4,792 of those approvals
  still hold; the other two, Graceful shark and Silky shark, lapsed when their wrong
  "Grey/Gray reef shark" aliases were removed, and he approved them again on October 26,
  2026 in [batch-18-rereview](Docs/GlobalBatchReview.md#owner-additions-2026-10-23),
  individually reviewed. He approved the four sharks and rays he asked for (Whitetip reef shark,
  Grey reef shark, Zebra shark, Reef manta ray;
  [batch-21](Docs/GlobalBatchReview.md#owner-additions-2026-10-23)) the same day, each
  individually reviewed. Approval of the Global copies does not carry over to the
  regional packs.
- **Release** exposes 4,798 records, all of Global's; the four regions show subsets of
  them. Tropical Pacific and Caribbean are retired regions. Bryce opened Global's
  pack-level Release gate (`GlobalRegion.swift`) on October 23, 2026. New installs start
  in Global; a stored region selection is kept, and a retired one is offered its
  replacement.
- **Debug** permits all 4,798 development records: Global's, which has no drafts,
  listed in Global and its regions. Debug and tests can still open the retired Caribbean
  (8) and Tropical Pacific (1,000) packs by ID as evaluation fixtures; no build lists them.

Saved identifications remain accessible independently of search access.
Global species text comes from FishBase and SeaLifeBase (release v26.06, CC BY-NC 4.0).
The app credits both on its Data Sources and Credits screen and links each species
to its source page.
Do not add `DEBUG` to Release, promote synthetic fixtures, or treat search quality
as human publication approval.

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
development team and provisioning. GitHub CI does not build the app (its hosted Xcode
could not); build and test it locally, and before merging app changes run
`Tools/CI/local_xcode_checks.sh` on a Mac with Xcode. It validates Debug, Release and
Internal settings, runs the unit and UI tests on a simulator, builds Release and
Internal, and checks the instrumentation boundary.

```sh
open DiveID.xcodeproj
xcodebuild -project DiveID.xcodeproj -scheme DiveID -showdestinations
```

**Build configurations.** The shared scheme runs **Debug** and archives **Release**.

| Configuration | Catalogue | Optimized | `DEBUG` | Bundle ID / name |
| --- | --- | --- | --- | --- |
| Debug | all development records | no (`-Onone`) | yes | `com.brycecameron.DiveID` / Dive ID |
| Release | publication-eligible only | `-O`, whole module | no | `com.brycecameron.DiveID` / Dive ID |
| Internal | all development records | `-O`, whole module | no (`DIVEID_INTERNAL`) | `com.brycecameron.DiveID.internal` / Dive ID Internal |

**Internal** is for measuring packs that hold drafts on an iPhone at
Release-like speed. It installs beside the Release app, never replaces it, shows an
"Internal build" banner on every screen, uses the production BM25 engine and has no
Core ML opt-in. It is not a distribution build and its results are not Release
results. Select it with Product → Scheme → Edit Scheme… → Run → Build Configuration,
or `xcodebuild -configuration Internal`. CI checks its settings from the project file
(`Tools/CI/static_xcode_settings.py`); `local_xcode_checks.sh` builds it.

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
for suite in TropicalPacificWorkbook CatalogImport CatalogReview GlobalMarineImport FishBaseIntake SemanticSearch/tests CI Evaluation; do
  python3 -m unittest discover -s "Tools/$suite" -p 'test_*.py' -v || suite_failures=1
done
test "$suite_failures" = 0
swift test
swift test -c release
python3 Tools/Evaluation/run_v05.py --configuration debug
```

GitHub CI runs the Python suites (including a project-file check that Release never
defines `DEBUG` or `DIVEID_INTERNAL`) and Linux/macOS SwiftPM, and requires both to
succeed. It does not build or test the iOS app; that is `Tools/CI/local_xcode_checks.sh`. The shell loop runs all eight suites and aggregates
their status; every command keeps a nonzero exit status on failure, and
`run_v05.py` returns the evaluation test's status.

The 46-case v0.5 development evaluation (fixture v2) passes every gate on the
regional packs ([report](Reports/V05DevelopmentEvaluation.json), refreshed
2026-10-26 for the Global regions; development results are unchanged since 2026-10-22).
With the production engine:

- **Development (the 8 Caribbean + 1,000 Tropical Pacific fixture records):** candidate recall
  34/34, top1 26/34, top3 33/34, top10 34/34, no-match 6/6, region conflicts 4/4,
  confidence 46/46.
- **Release (each case in its retired region's replacement: Caribbean cases in Tropical
  Atlantic Regions, 1,038 approved records; Tropical Pacific cases in Indo-Pacific Regions,
  3,590):** all 46 cases are eligible, giving candidate recall 33/34, top1 19/34,
  top3 26/34, top10 30/34, no-match 6/6, region conflicts 4/4, confidence 46/46. Release
  asserts the production engine's gates, not each case: six positive cases miss their rank
  limit (`v05-05-paraphrase`, `v05-09-diagnostic`, `v05-09-paraphrase` and
  `v05-10-paraphrase` miss the top ten, as in Global; `v05-15-diagnostic` and
  `v05-16-diagnostic` rank 4 and 7 against a limit of 3). The structured full-pack
  comparison engine is reported only.

Its descriptions are synthetic and v2 was written after v1 results were seen, so
this is development evidence, not independent diver holdout data or publication
approval. The first run's failures and the remaining limitations are in
[V05DevelopmentEvaluation.md](Docs/V05DevelopmentEvaluation.md). The legacy
100-case benchmark includes an opt-in frozen cohort; routine tests leave it closed.

## Rebuild catalogue data

```sh
python3 Tools/CatalogReview/regenerate_caribbean.py
python3 Tools/CatalogImport/import_tropical_pacific.py
python3 Tools/CatalogReview/prepare_source_review_pass.py
python3 Tools/CatalogReview/prepare_review_batch.py
python3 Tools/CatalogReview/verify_source_review_reproducibility.py
python3 Tools/FishBaseIntake/publish_global.py   # Global: drafts plus recorded batch approvals
```

Global approvals come only from batch decisions recorded with
`Tools/CatalogReview/global_batches.py record` ([batch review](Docs/GlobalBatchReview.md)).
`publish_global.py` marks a record verified only while its content matches the
approved fingerprint.

Use the validated overlay/import inputs rather than editing generated records.
Stable IDs, original provenance and named human review decisions must survive
regeneration. See [Pacific import documentation](Docs/TropicalPacificCatalogue.md)
and [candidate readiness record](Reports/V05CandidateReadiness.json). Publication
approval and on-device readiness are separate from import/build success.
