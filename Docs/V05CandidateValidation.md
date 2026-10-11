# Validate the v0.5 candidate on an iPhone

Scope: offline description search, region selection, results/details and durable
saved identifications. Version 0.5 / build 2, iPhone only, minimum iOS 18.0.
Photo identification is unavailable; Core ML remains experimental and is not a
candidate requirement. Default engine: BM25 + biological ranking, candidate limit
50, display limit ten. Do not change defaults or define DEBUG in Release.

Current pack counts are 8 Caribbean (pack 3) and 384 Pacific (pack 2), all draft.
There are zero real approved records. Release must show the no-reviewed-catalogue
state, disable search and retain Saved Identifications access. Positive Release
search and Release region switching are blocked until real reviews approve records.

The inspected main Actions run [38101875174](https://github.com/bryce496913/Dive-ID/actions/runs/38101875174)
for `e227ad3b616fda09b90421e0fb4c56efc5ff5cad` passed Debug/Release product
settings, both SwiftPM jobs and all six Python suites. Hosted build-for-testing
failed on two actor-isolated formatter calls and immutable profile assignments in
Xcode-only tests. The repair isolates those tests on MainActor and constructs new
decoded fixtures without making production fields mutable. Unit/UI execution must
be confirmed by the repair PR's actual run; portable passes do not establish it.

## Record the source and toolchain

Use a clean checkout of the candidate SHA in `Reports/V05CandidateReadiness.json`.
Record `git rev-parse HEAD`, `git status --short`, `xcodebuild -version`, installed
SDKs, device OS/build, signed bundle identifier, actual version/build from the built
Info.plist, and the signing team used. Build 2 only exceeds the known repository
build 1: compare it against actual distribution history before distributing later.
This pass does not authorize submission or publication.

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -showdestinations
xcrun simctl list devices available
xcrun devicectl list devices
```

Select an available **iPhone simulator running iOS 18+** by its UDID; do not select
My Mac, a generic destination for tests, or an unavailable hardcoded model.

```sh
SIMULATOR_ID='<available iPhone simulator UDID>'
mkdir -p /tmp/diveid-v05
for CONFIGURATION in Debug Release; do
  xcodebuild -project DiveID.xcodeproj -alltargets -configuration "$CONFIGURATION" \
    -sdk iphonesimulator -showBuildSettings -json \
    > "/tmp/diveid-v05/settings-$CONFIGURATION.json"
  python3 Tools/CI/validate_xcode_settings.py \
    "/tmp/diveid-v05/settings-$CONFIGURATION.json" "$CONFIGURATION"
done
```

Also inspect the resolved **DiveID app** settings: MARKETING_VERSION=0.5,
CURRENT_PROJECT_VERSION=2, IPHONEOS_DEPLOYMENT_TARGET=18.0, supported iPhone platforms.
Debug must inherit DEBUG; Release must not contain DEBUG in active conditions or
`-DDEBUG` in Swift flags. Both test targets require distinct nonempty products;
DiveIDTests inherits DIVEID_XCODE_HOSTED_TEST. Static project inspection is not a
substitute for this resolved-setting evidence or inspection of the built Info.plist.

## Build and test the installed Debug simulator app

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/diveid-v05/debug CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/diveid-v05/debug-build.xcresult build-for-testing
```

After a successful build, run **each command independently**, even if another
fails. Do not connect them with `&&` or stop after a failure in another stage.
Use fresh result-bundle paths for repeated runs; preserve previous evidence.

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/diveid-v05/debug CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/diveid-v05/debug-unit.xcresult \
  test-without-building -only-testing:DiveIDTests

xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/diveid-v05/debug CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/diveid-v05/debug-packaging.xcresult test-without-building \
  -only-testing:DiveIDTests/TropicalPacificCatalogueTests/testProductionRepositoryLoadsTropicalPacificFromBuiltApplicationBundle

xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/diveid-v05/debug CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/diveid-v05/debug-ui.xcresult \
  test-without-building -only-testing:DiveIDUITests
```

## Release build and test destinations

Build the **actual Release app** separately without testability or DEBUG overrides:

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/diveid-v05/release-device CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/diveid-v05/release-device-build.xcresult build
```

This unsigned generic-device build is not installed-app evidence. Build/run Release
on the connected iPhone in Xcode using authorized signing, with a separate derived
data path. The shared scheme's Run action defaults to Debug: explicitly choose
Release in Edit Scheme > Run for this device check, then restore Debug afterward.
Profile defaults to Release; neither a Profile launch nor a UI label can prove
which engine ran without recording configuration and engine evidence.

For simulator-hosted unit testing of optimized code, use a separate test build:

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/diveid-v05/release-tests CODE_SIGNING_ALLOWED=NO \
  ENABLE_TESTABILITY=YES -resultBundlePath /tmp/diveid-v05/release-test-build.xcresult \
  build-for-testing
```

Run the complete unit target and explicit packaging test with `test-without-building`,
`-configuration Release`, this same destination/path and distinct result bundles,
as for Debug. Testability enables @testable imports; it is **not** DEBUG and this
instrumented test build is not the separately built device candidate.
The existing core-navigation UI test assumes a searchable Debug catalogue; it is
not a valid successful-search assertion for the empty Release subset. Run the
photo-disabled/saved-screen UI test in Release and manually verify the Release
catalogue gate. Do not silently count the unexecuted positive Release flow as passed.

## Installed-app functional checklist (currently unexecuted)

Record each item independently with configuration, device and evidence location.
Keep Wi-Fi and cellular off while exercising the app; leave saved storage intact.

1. Debug: verify Caribbean 8 / Pacific 384, switch between them, relaunch and
   confirm selection persists. Release: verify zero reviewed regions, disabled
   search, accessible saved snapshots and unavailable photo action.
2. Debug: run the committed Pacific ray/dartfish/waspfish/puffer positive cases and
   freshwater-lily-pad frog no-match. Record actual ranks, engine, pack and labels.
   Also run the known failing v0.5 freshwater-sand and regional probes; record the
   failures rather than substituting easier queries.
3. Open a result, inspect species/source/pack details, return to results and verify
   cached results. Back out of a loading search and verify no late results replace
   a newer search. Repeat 30 completed search flows and observe session cleanup.
4. Save a sighting, terminate the process, relaunch and reopen the saved snapshot.
   Remove it, terminate/relaunch again and confirm removal. Verify a failed save
   or removal reports an error and retains the last confirmed state; do not
   damage a user's file to simulate a failure. Use a dedicated test installation.
5. Background/foreground during a pending search, on results, and on detail/saved
   screens. Check correct navigation/state, responsive retry and no phantom saved
   state after suspension. Process termination and background suspension are
   separate checks.
6. In default Debug and Release, never describe BM25 as semantic inference. If
   separately investigating the Debug-only experimental switch, record requested
   and actual engines; missing/invalid model artifacts must say BM25 fallback.
   Synthetic embedding providers are not real-model evaluation evidence.

## Actual iPhone latency and memory protocol (no measurements yet)

Use a real iPhone, not simulator timings or Linux XCTest durations. Record model,
iOS version/build, Xcode/Instruments version, configuration, candidate SHA/build,
battery/thermal state, attached-debugger status, offline connectivity, selected
pack/count, candidate limit, actual engine and exact query/case ID.

Measure **search-to-visible-results**, from Find Matches tap to stable first results
or no-match state, with an Instruments app trace or timestamped screen recording.
Record which method and sampling/frame resolution were used; do not equate this
with pure ranking time. If engine-only timing is later instrumented, report it as
a separate metric. Five cold trials each start with process termination/relaunch
(first search, no in-process document cache; OS filesystem caches are not flushed).
Run 20 warm trials of the same case, then 30 varied completed searches with
results/detail/back navigation. Repeat per development region. Report raw samples,
median, p95 (nearest-rank), failures and sample counts; do not discard failed trials.

Use Instruments Allocations/VM Tracker or the Xcode memory gauge, consistently,
to record baseline after launch, first-search peak, repeated-search peak and settled
memory after leaving all result/detail flows. Record the metric (for example resident
memory or physical footprint), units, sampling interval and tool. Preserve the
trace; a bounded session count alone does not prove bounded device memory.

Measure Debug development search as Debug, never as Release performance. Release
has no approved catalogue and cannot currently produce cold/warm identification
measurements. Its launch, empty-catalogue and saved-record behavior can still be
checked. The outstanding publication gate must not be bypassed to obtain numbers.

Worksheet (leave values empty until actually observed):

| Field | Recorded value |
| --- | --- |
| Candidate SHA / marketing version / build | |
| Device / iOS build / tool versions | |
| Configuration / debugger / thermal state | |
| Pack / count / actual engine / case | |
| Timing method / resolution / cold or warm | |
| Raw samples / median / p95 / errors | |
| Memory metric / baseline / peaks / settled | |
| Functional checklist / logs / trace paths | |

Current execution evidence and the exact unexecuted checks are listed in
`Reports/V05CandidateReadiness.json`. No installed iOS build or device performance
claim may be inferred from portable test results.

## Resolved bundle identifier and separate installation products

Derive the identifier from the app target, not the test runner or an example identifier:

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath /tmp/diveid-v05/debug -showBuildSettings -json \
  > /tmp/diveid-v05/app-settings.json
APP_BUNDLE_ID=$(python3 -c 'import json; d=json.load(open("/tmp/diveid-v05/app-settings.json")); print(next(x["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"] for x in d if x["target"] == "DiveID"))')
xcrun simctl install "$SIMULATOR_ID" /tmp/diveid-v05/debug/Build/Products/Debug-iphonesimulator/DiveID.app
xcrun simctl launch "$SIMULATOR_ID" "$APP_BUNDLE_ID"
```

For a signed physical-device build, resolve settings again for that device and
configuration; install only its `Release-iphoneos/DiveID.app` from the separate
`release-device` derived-data directory. Never install a simulator product on a phone.

The Python CI matrix independently discovers all six suites below with fail-fast
disabled. Run each independently locally and retain each exit status and log:

```sh
python3 -m pip install -r Tools/TropicalPacificWorkbook/requirements.txt -r Tools/CatalogImport/requirements.txt
python3 -m unittest discover -s Tools/TropicalPacificWorkbook -p 'test_*.py' -v
python3 -m unittest discover -s Tools/CatalogImport -p 'test_*.py' -v
python3 -m unittest discover -s Tools/CatalogReview -p 'test_*.py' -v
python3 -m unittest discover -s Tools/SemanticSearch/tests -p 'test_*.py' -v
python3 -m unittest discover -s Tools/CI -p 'test_*.py' -v
python3 -m unittest discover -s Tools/Evaluation -p 'test_*.py' -v
```

SwiftPM deliberately excludes UIKit/SwiftUI integration tests. Xcode's synchronized
DiveIDTests group includes them; its shared scheme includes both complete test targets.
The app-resource assertion is compiled only with DIVEID_XCODE_HOSTED_TEST and checks
the actual APPL host before loading bundle-only resources. Missing app resources are
failures, not reasons to skip. SwiftPM uses its declared library/test resource bundles
on Linux and macOS; the OS alone never establishes a hosted app bundle.
