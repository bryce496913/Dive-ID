# Validate the v0.5 candidate on an iPhone

Scope: offline description search, region selection, results/details and durable
saved identifications. Version 0.5 / build 2, iPhone only, minimum iOS 18.0.
Photo identification is unavailable; Core ML remains experimental and is not a
candidate requirement. Default engine: BM25 + biological ranking, candidate limit
50, display limit ten. Do not change defaults or define DEBUG in Release.

Current pack counts are 8 Caribbean (pack 3: 2 approved, 6 draft) and 384 Pacific
(pack 2: all draft). Bryce approved Atlantic Blue Tang and Queen Angelfish on
October 12, 2026; exact IDs and source evidence are in CataloguePublicationReview.md.
Release must offer only those two Caribbean species. Pacific remains unavailable;
test recovery from a persisted Pacific selection and retain Saved Identifications
access. Cases targeting other species are inapplicable to this Release subset.
An approved catalogue does not establish installed-device readiness.

The approval candidate's hosted run [38299609043](https://github.com/bryce496913/Dive-ID/actions/runs/38299609043)
passed Xcode unit/UI, both SwiftPM jobs and all Python jobs. Its tested head
`7315fc7de0482acc4bb9ad1c581ec23e735224f3` has the same tree as merged main
`10af439db9dc4d3e160a2f9bb0432d4fb2a80ea3`. This is hosted simulator evidence,
not physical-device validation. Use [PhysicalReleaseValidation.md](PhysicalReleaseValidation.md)
for the signed device install commands, frozen case checklist and evidence record.

## Record the source and toolchain

Use a clean checkout of the exact candidate SHA being validated; older readiness
reports describe their own recorded commits.
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

With Xcode 16.4, select an available **iPhone simulator running iOS 18** by its UDID; do not select
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
not a substitute for the two-species Release checklist. Run the
photo-disabled/saved-screen UI test in Release and manually verify the Release
catalogue gate. Do not silently count the unexecuted positive Release flow as passed.

## Installed-app functional checklist (currently unexecuted)

Record each item independently with configuration, device and evidence location.
Keep Wi-Fi and cellular off while exercising the app; leave saved storage intact.

1. Debug: verify Caribbean 8 / Pacific 384, switch between them, relaunch and
   confirm selection persists. Release: verify Global with 4,796 records (4,798 once batch-18-rereview is approved) as the new-install default, Caribbean
   with exactly two approved species, unavailable Pacific, accessible saved snapshots and unavailable photo action.
2. Debug: run the committed Pacific ray/dartfish/waspfish/puffer positive cases and
   freshwater-lily-pad frog no-match. Record actual ranks, engine, pack and labels.
   Also run the frozen v0.5 freshwater-sand and regional probes; record actual
   outcomes rather than substituting easier queries.
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
measurements use only the two approved Caribbean records. Keep its samples separate
from Debug development-pack samples. No physical-device timings have been collected.

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

Current physical-device preparation and the exact unexecuted checks are listed in
`Reports/PhysicalReleaseValidation.json`; older readiness reports describe their
own recorded candidates. No installed iOS build or device performance
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

## Release device checklist (prepared 2026-10-22; unexecuted)

For Bryce to run on an iPhone with a Release build. **No result below has been
observed on a device.** The expected results come from running the same Release
code and data on a Linux host: first at `main` `2766a55`, then re-checked unchanged
(Debug and Release) after the ranking and index changes of 2026-10-22 on
`claude/quirky-darwin-hjjg7c` (`6a10cb4`). Host timings are not device timings, so
none are listed as expectations.

### What this Release build contains

- **Approved records:** Release exposes only approved records. At this commit those
  are **2 Caribbean species** (Atlantic Blue Tang and Queen Angelfish) and **4,796 of the
  4,798 Global records**, approved 2026-10-23 (`Docs/GlobalBatchReview.md`). The other 2
  are drafts awaiting re-review (batch-18-rereview).
- **Global** is in Release and is the default region for new installs (owner decision,
  2026-10-23).
- **Tropical Pacific** has 0 approved records and must not appear either.
- **The region picker** therefore offers Caribbean only, showing 2 species.

### 1. Install

1. **Check out the build:** on the Mac, check out the commit being tested
   (`755efea` was current `main` on 2026-10-22). Record the full SHA in the results table below.
2. **Connect the iPhone:** unlock it and trust the Mac. Developer Mode must be on
   (Settings → Privacy & Security → Developer Mode).
3. **Build:** follow "Capture and build on a Mac" in
   [InstalledReleaseValidation.md](InstalledReleaseValidation.md). It builds with
   `xcodebuild … -configuration Release -destination "platform=iOS,id=$DEVICE_ID"`,
   then installs and launches with `xcrun devicectl`.
   - From the Xcode UI instead: Product → Scheme → Edit Scheme… → Run → Build
     Configuration: **Release**, then Run on the iPhone.
4. **Check the build:** confirm in the build log or `release-settings.json` that
   `DEBUG` is absent from the active compilation conditions.
5. **Use the installed copy for timings:** after installing, stop the debugger
   (Product → Stop) and launch the app from the Home Screen. A debugger slows
   launch and searches.

### 2. Ten searches

Go to Home → Describe What You Saw, type the text exactly, then tap Find Matches.
The Release catalogue has 2 species, so a list holds at most two entries. Record
what is shown, in order, and the match-strength label.

| # | Type exactly | Expected results, in order (strength) | Intended species | Note |
| --- | --- | --- | --- | --- |
| 1 | Bright blue fish with a yellow spine near the tail | Atlantic Blue Tang (Possible match), Queen Angelfish (Weak match) | Atlantic Blue Tang | |
| 2 | Atlantic blue tang | Atlantic Blue Tang (Good match), Queen Angelfish (Weak match) | Atlantic Blue Tang | name search |
| 3 | Oval blue surgeonfish grazing on algae over the reef | Atlantic Blue Tang (Weak match), Queen Angelfish (Weak match) | Atlantic Blue Tang | |
| 4 | Queen angelfish | Queen Angelfish (Possible match) | Queen Angelfish | name search |
| 5 | Blue and yellow angelfish with a dark spot ringed in blue on its forehead | Queen Angelfish (Weak match), Atlantic Blue Tang (Weak match) | Queen Angelfish | |
| 6 | Disc shaped yellow fish with electric blue edges and a yellow tail | Atlantic Blue Tang (Possible match), Queen Angelfish (Weak match) | Queen Angelfish | **known miss**: the intended species ranks second |
| 7 | Something swimming on the reef | Atlantic Blue Tang (Weak match), Queen Angelfish (Weak match) | none (vague) | both shown weakly |
| 8 | Angelfish | no possible matches | Queen Angelfish | **known gap**: a bare group name finds nothing |
| 9 | A green frog sitting on a leaf | no possible matches | none (not marine) | out of domain |
| 10 | A large grey shark cruising in open water | no possible matches | none (not in the Release catalogue) | must not show a draft species |

**Also check:**
- Change Dive Region lists Caribbean (2 species) only. Global and Tropical Pacific
  are absent.
- Open result 1: Record review status reads "Human-reviewed and approved for
  publication", and the Source link opens its source page.
- Home → Data Sources and Credits opens and shows the FishBase and SeaLifeBase
  citations.

### 3. Timing

Use the iPhone's screen recording (Control Center) with the debugger detached.
Read times from the recording, and note its frame rate.

- **Cold launch to first result:**
  1. Force-quit Dive ID from the app switcher.
  2. Start recording, then tap the app icon.
  3. Go to Describe What You Saw, type search 1 and tap Find Matches.
  4. Record two intervals: icon tap → Home visible, and Find Matches tap → results
     visible. Repeat 5 times.
- **Warm search:** without quitting, run searches 1, 4 and 5 five times each, going
  back between runs. Record Find Matches tap → results visible.
- **Report:** raw samples, median, and nearest-rank p95. With 5 samples, p95 is the
  maximum; label it descriptive.

### 3b. First search after install, later launches, cancellation, offline (unexecuted)

The search index is now prepared in the background when Describe What You Saw
opens, and stored in the app's Caches folder for later launches
([GlobalPackEvaluation.md](GlobalPackEvaluation.md#cold-index-loading-2026-10-22)).

1. **Fresh install:** delete Dive ID, install the build, and launch from the Home
   Screen. Open Describe What You Saw and tap Find Matches on search 1 **at once**.
   Record Find Matches tap → results visible. This is the cold case: the index is
   still being prepared.
2. **Later launch:** force-quit, relaunch and repeat. The index now loads from the
   Caches folder. Record the same interval, 5 times.
3. **Waited:** relaunch, open Describe What You Saw, wait 10 s, then search. Record
   the interval.
4. **Responsiveness:** while step 1 is preparing, type and scroll. Note any stutter.
5. **Cancellation:** submit search 1, then tap Back before results appear, and submit
   search 4. Only search 4's results may appear, and the app must stay responsive.
6. **Offline:** turn on Airplane Mode (Wi-Fi and cellular off), force-quit,
   relaunch and run searches 1 and 4. Results must match the table above.

### 4. Memory (Xcode)

Run the Release build from Xcode on the iPhone, so the debugger is attached for
this part only. Open the Debug navigator (⌘7) → Memory and record the gauge at:

- **Launch:** after launch, on Home.
- **First search:** the peak during the first search (search 1).
- **Ten searches:** after all ten searches.
- **Settled:** after returning to Home, 30 s later.

If any value looks high, profile with Instruments → Allocations (or VM Tracker) and
save the trace. Record the metric name: the gauge shows memory use, Instruments
shows physical footprint.

### 5. Where to record results

Fill in the table below and save screen recordings and traces outside the
repository. Copy the summary into `Reports/InstalledReleaseValidation.json` under a
new run entry with the commit SHA. Do not overwrite earlier runs.

| Field | Result |
| --- | --- |
| Commit SHA / version / build | |
| Configuration and engine (Release, production BM25 with biological ranking) | |
| Catalogue fingerprint (see below) | |
| iPhone model / iOS build / Xcode version | |
| DEBUG absent (yes/no, where checked) | |
| Region picker contents | |
| Searches 1–10: shown results and strengths (match / differs) | |
| Cold launch → Home (5 samples, median, max) | |
| Cold Find Matches → results (5 samples, median, max) | |
| Warm search (15 samples, median, p95) | |
| Fresh install, first search at once / later launch (5) / after waiting 10 s | |
| Typing while preparing; cancellation; offline searches 1 and 4 | |
| Memory: launch / first-search peak / after ten / settled (metric) | |
| Detail page, source link, credits screen | |
| Recordings and trace locations | |
| Problems seen | |

**Catalogue fingerprint.** On the Mac, at the tested commit, record the stable
content key the app uses for each pack:

```sh
python3 -c 'import sys
for p in sys.argv[1:]:
    h = 0xcbf29ce484222325
    for b in open(p, "rb").read(): h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    print(p, format(h, "016x"))' DiveID/Resources/IdentificationPacks/*/Creatures.json
```

### Optional: Global in an Internal build (experimental only)

Global is also in Release since 2026-10-23. To time its development build on the iPhone,
use the **Internal** configuration rather than Debug: it is optimized like Release
(`-O`, whole module) and has no `DEBUG`, but it opens the development catalogue. It
installs as a separate app, **Dive ID Internal** (`com.brycecameron.DiveID.internal`),
beside the Release app, so it cannot disturb the Release checks above or their saved
identifications. Every screen shows a yellow "Internal build" banner. It always uses
the production BM25 engine with biological ranking; the Core ML opt-in is Debug-only.

1. **Build:** Product → Scheme → Edit Scheme… → Run → Build Configuration:
   **Internal**, then Run on the iPhone. Or
   `xcodebuild … -configuration Internal -destination "platform=iOS,id=$DEVICE_ID"`.
   Stop the debugger and launch **Dive ID Internal** from the Home Screen for timings.
2. **Check:** the banner is visible, and Change Dive Region lists Global,
   Tropical Pacific (Experimental) and Caribbean with their full record counts.
3. **Select Global**, then time it:
   - **Fresh install:** delete Dive ID Internal first, then time the first Global
     search submitted at once. On the Linux host, readiness takes 4.9 s in Release.
   - **Later launch:** time it again after a relaunch. The stored index makes the
     host figure 0.9 s.
   - **Warm search:** host median 54 ms.
   - **Memory:** the gauge at launch, the first-search peak and after ten searches.
     On the host, the full Global pack peaks at about 186 MiB.
   - The step-by-step version, with diagnostics, signposts and a results table, is the
     [Internal device performance test](#internal-device-performance-test-prepared-2026-10-23).
4. **Record** these as Internal numbers with the commit SHA. They are not Release
   results, and Global's search quality on them is development evidence only.

A Debug build also opens Global, but report Debug timings only as Debug: Debug keeps
testability and `DEBUG`-only diagnostics and is unoptimized (`-Onone`, checked in CI from the project file).

## Internal device performance test (prepared 2026-10-23)

For Bryce to run on his iPhone with the **Internal** configuration (see
[Optional: Global in an Internal build](#optional-global-in-an-internal-build-experimental-only)):
optimized like Release, installed as **Dive ID Internal**, opening the full draft
catalogue. **Nothing below has been observed on an iPhone.** The behaviours were
checked in tests first (`FirstUsePerformanceTests`, `InternalInstrumentationTests`,
`SearchIndexStoreTests`); the host numbers are host numbers only.

### What the Internal build adds (Debug too; never Release)

All of it is compiled only under `DEBUG || DIVEID_INTERNAL`
(`DiveID/Core/Services/SearchPerformanceInstrumentation.swift` and its call sites).
`Tools/CI/local_xcode_checks.sh` builds the Release app and fails if any of its strings or
the signpost API appear in it (`Tools/CI/check_internal_instrumentation.py`); it also checks that they are
present in the Internal and Debug apps, so the check is known to see them.
`InternalInstrumentationTests` does the same for the SwiftPM test bundle on macOS in
both `swift test` and `swift test -c release` (on Linux the test runner does not carry
these strings even in Debug, so the scan is skipped there). No ranking, content or Release behaviour changed.

**Signpost intervals** (Instruments → Points of Interest, subsystem
`com.brycecameron.DiveID.performance`; each carries the pack ID, never query text):

| Interval | Starts | Ends |
| --- | --- | --- |
| Catalogue load | a pack is decoded and validated (not a cached pack) | the pack is ready |
| Index load from store | a stored index file exists and is read | loaded, or rejected (message says which) |
| Index build | documents and the BM25 index are built | the index is ready |
| Background preparation | Describe What You Saw opens (or the dive region changes) | the index is ready; the message is the index source |
| Query to first result | Find Matches is tapped | results, "No useful matches" or an error is on screen; `cancelled` if you go back first |

**Diagnostics row**, on Describe What You Saw below Find Matches (scroll down):

```
Internal search diagnostics
Index: loaded from store · Ready: 0.91 s · Last query: 62 ms
Catalogue 0.74 s + index 0.17 s
[Delete stored index] [Corrupt stored index]
```

- **Index:** where the selected pack's index came from on this launch: `built` (no
  stored index), `loaded from store`, or `rebuilt after invalid store` (a stored
  file existed but failed validation, was deleted and rebuilt). `preparing…` until ready.
- **Ready:** from the screen opening (preparation start) to the index being ready:
  catalogue load plus index load or build. It is kept for the first preparation of each
  launch, so reopening the screen does not replace it. The second line splits it.
- **Last query:** Find Matches tap to the first state on the results screen (the
  `Query to first result` interval). A suffix says `(no results)`, `(failed)` or
  `(cancelled)`; none means results were shown.
- **Delete stored index** removes the selected pack's file from the app's Caches
  folder. **Corrupt stored index** overwrites the middle half of it with random bytes,
  keeping its length, header and checksum, so only validation can catch it. Both change
  only the file; the index in memory stays, so **force-quit and relaunch** to test
  recovery. The row confirms how many files were changed.

### Host baseline (re-measured 2026-10-23; host results, not iPhone results)

Measured with `GlobalPackPerformanceTests` (`swift test -c release`) on a GitHub-hosted
**macos-15 runner** (Apple silicon virtual machine, 3 cores, macOS 15.7.9), twice at
the current catalogue and once, on the same runner, at `7b93702` (the commit before the 8
Caribbean records joined Global). Each launch is a fresh repository and index store in
one process, so the file cache is warm. **These are host numbers, not iPhone numbers**,
and this runner is a different machine from the Linux container behind the earlier
figures (4.93 s / 0.89 s / 54 ms), so compare like with like.

| Global pack | Fresh install: screen to search-ready | Later launch (stored index) | Warm query median (p95) | First query without preparation | Index build | Stored index |
| --- | --- | --- | --- | --- | --- | --- |
| 4,794 records, run 1 | 6.74 s | 0.89 s | 140 ms (192 ms) | 6.94 s | 4.72 s | 2.99 MB |
| 4,794 records, run 2 | 6.39 s | 0.74 s | 140 ms | 6.59 s | 4.77 s | 2.99 MB |
| 4,786 records (before), same runner | 6.26 s | 0.69 s | 140 ms | 6.45 s | 4.97 s | 2.99 MB |

Tropical Pacific (1,000) on the same runner: 0.74–0.95 s fresh, 0.08–0.10 s later
launch, 54–56 ms warm median. Caribbean (8): about 10 ms and 5 ms, 12 ms warm.

- **The 8 Caribbean records make no measurable difference.** The 4,786 and 4,794 runs
  differ by less than the two 4,794 runs differ from each other.
- **Fresh readiness** is decode (0.6 s) + documents (0.8 s) + index build (4.7 s) on
  this runner; the index build is about 70% of it.
- **Warm queries** are slower here than on the Linux container (140 ms against 54 ms
  median) at the same code, which is the hardware difference. An iPhone could land on
  either side; only the device test answers that.
- Full JSON for each run is in the CI artifacts of
  [run 39970473554](https://github.com/bryce496913/Dive-ID/actions/runs/39970473554).

### 1. Install

1. **Check out** the commit being tested on the Mac and record its full SHA.
2. **Connect the iPhone**, unlocked and trusted, with Developer Mode on.
3. **Build and install Internal:** Product → Scheme → Edit Scheme… → Run → Build
   Configuration: **Internal**, then Run on the iPhone. Or, with `DEVICE_ID` from
   `xcrun devicectl list devices`:

   ```sh
   xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Internal \
     -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath /tmp/diveid-internal build
   xcrun devicectl device install app --device "$DEVICE_ID" \
     /tmp/diveid-internal/Build/Products/Internal-iphoneos/DiveID.app
   ```
4. **Check:** the yellow "Internal build" banner shows on every screen, and Describe What
   You Saw shows the diagnostics row below Find Matches.
5. **Detach:** after installing, stop the debugger (Product → Stop) and launch
   **Dive ID Internal** from the Home Screen for every timing below. Turn on Airplane
   Mode; the app needs no network.

### 2. Test sequence

Use **Global** throughout; it is the slow case. Record each step in the
results table. "Search A" is `Bright blue fish with a yellow spine near the tail`.
Have it on the clipboard (copy it from Notes) so it can be pasted at once.

**A. Fresh install, search at once**

1. Delete Dive ID Internal from the iPhone (long-press → Remove App → Delete App), then
   install it again (step 1.3). This removes the stored index.
2. Launch it, open Describe What You Saw and paste search A **first**.
3. Tap Change, select Global. You return to Describe What You Saw with the
   text kept, and Global's preparation starts now. Tap **Find Matches immediately**.
4. **Expect:** the results screen shows "Searching the Global dive
   region…" with a progress indicator while the index is prepared, then results. Never
   an empty list, "No useful matches" or an error while it waits.
5. **Record:** the time from tap to results (stopwatch or screen recording), the first
   three results, then go back and read the row: `Index: built`, its Ready time and
   Last query. The Last query is the tap-to-results time.

**B. Back mid-search**

1. Still on this launch, tap **Delete stored index**, force-quit, relaunch, open
   Describe What You Saw (Global stays selected), paste search A and tap Find Matches
   at once; the index is building again.
2. Tap **Back** before results appear.
3. **Expect:** you return to Describe What You Saw at once; the row says
   `Last query: … (cancelled)` once the screen refreshes. Tap Find Matches again: the
   progress view shows, then the same results as A. No spinner stays behind, and the
   app stays responsive (try scrolling the description while it prepares).

**C. Relaunch, and force-quit during the build**

1. Force-quit, relaunch and open Describe What You Saw. **Expect:** `Index: loaded
   from store`, with a Ready time much shorter than A's. Run search A and confirm the
   same first three results. Repeat this relaunch 3 times and record each Ready time.
2. Tap **Delete stored index**, force-quit and relaunch. Open Describe What You Saw and,
   within about one second (well before the index is ready), **force-quit again** from
   the app switcher. Relaunch and open the screen.
3. **Expect:** `Index: built` (the interrupted launch never wrote a file), and search A
   gives the same results. Force-quit and relaunch once more: `loaded from store`.

**D. Delete the stored index**

1. Tap **Delete stored index**; the row says it deleted 1 file. Force-quit and relaunch.
2. **Expect:** `Index: built`, with a Ready time similar to A's; search A gives the same
   results. The next relaunch shows `loaded from store` again.

**E. Corrupt the stored index**

1. Tap **Corrupt stored index**; the row says it corrupted 1 file. Force-quit and relaunch.
2. **Expect:** `Index: rebuilt after invalid store`, never `loaded from store`, and
   search A gives the same results. The next relaunch shows `loaded from store` again.

**F. Five warm queries**

With the index ready (`loaded from store` or after A to E), without quitting, run each
search below once, tapping Back between them, and record each Last query:

1. `Bright blue fish with a yellow spine near the tail`
2. `Oval blue surgeonfish grazing on algae over the reef`
3. `Blue and yellow angelfish with a dark spot ringed in blue on its forehead`
4. `A large grey shark cruising in open water`
5. `Something swimming on the reef`

Report the five values, their median, and the maximum (with five samples, nearest-rank
p95 is the maximum; label it descriptive). If one is close to a threshold below, run
search 1 another 20 times for a real p95.

### 3. Instruments trace with the signposts

1. In Xcode: Product → Scheme → Edit Scheme… → **Profile** → Build Configuration:
   **Internal**. (Profile defaults to Release, which has no signposts.)
2. Product → Profile (⌘I) on the iPhone, choose the **Time Profiler** template (it
   includes **Points of Interest**). Or add the **os_signpost** instrument to a Blank
   template, filtered to subsystem `com.brycecameron.DiveID.performance`.
3. Record, then run step A (or C/D/E) and two warm searches in the app. Stop.
4. In the Points of Interest track, select the list view (Summary: Intervals) to read
   each interval's duration: Catalogue load, Index load from store or Index build,
   Background preparation, Query to first result.
5. Save the trace (File → Save) outside the repository and note its path.

From the command line instead (after installing the Internal app):

```sh
xcrun xctrace record --template 'Time Profiler' --device "$DEVICE_ID" \
  --attach 'DiveID' --time-limit 60s --output ~/Desktop/diveid-internal.trace
```

### 4. Results

| Field | Result |
| --- | --- |
| Commit SHA / version / build | |
| iPhone model / iOS build / Xcode version | |
| Configuration (Internal), banner seen, debugger detached, Airplane Mode | |
| A. Fresh install: tap → results (s); row: source / Ready / Last query | |
| A. Progress shown while waiting; first three results | |
| B. Back mid-search: returned at once (yes/no); row says cancelled; retry results match A | |
| C. Relaunch Ready ×3 (source); search A results match | |
| C. Force-quit during build → relaunch source; results match | |
| D. Delete → source / Ready; results match; next launch source | |
| E. Corrupt → source / Ready; results match; next launch source | |
| F. Warm Last query ×5 (ms); median; max | |
| Memory gauge: launch / first-search peak / after F (metric) | |
| Instruments: Catalogue load / Index load or build / Background preparation / Query to first result | |
| Trace and recording locations | |
| Problems seen | |

### 5. When further optimization becomes necessary (proposed thresholds)

These are proposals for Bryce to accept or change, not decisions. Nothing has been
optimized. Read them against the iPhone results above, not the host numbers. Any one
breached on the device would make optimization the next step.

| Measure (Global, Internal build, iPhone) | Optimize if | Host today |
| --- | --- | --- |
| Fresh install: Find Matches tapped at once → results (step A) | **over 8 s** | 6.6–6.9 s macOS runner; 4.9 s Linux container (earlier) |
| Rebuild after a deleted or invalid store (steps D, E) | **over 8 s** | as fresh install |
| Later launch: Ready with `loaded from store` (step C) | **over 1.5 s** | 0.74–0.89 s |
| Warm query: Last query, five samples (step F) | **any over 500 ms, or median over 300 ms** | engine median 139 ms macOS VM, 54 ms Linux |
| Memory: first-search peak | **over 300 MB** | about 186 MiB resident (Linux) |

Whatever the timing, these are defects to fix rather than optimizations: wrong or empty
results while waiting, a progress view that never ends, a session left behind after
Back, or `loaded from store` after a corrupt or older index.

Reasoning:

- **Fresh install and rebuild, 8 s.** It happens once per install, and again after
  every app update, because the stored index is keyed to the app build. The screen
  shows progress throughout. Around 10 s is the usual limit for keeping a person's
  attention on one task, and 8 s leaves margin for slower iPhones and a warm device.
  On the host, about 70% of it is the index build (4.7 s of 6.4 s on macOS), so that
  would be the first place to look.
- **Later launch, 1.5 s.** It happens on every cold launch, and a diver often searches
  within seconds of opening the screen, so this is the wait people meet most. The host
  needs about 0.9 s; 1.5 s means the device is clearly slower than the host and the
  first search of a launch would visibly wait.
- **Warm query, 300 ms median and 500 ms maximum.** Up to roughly 100 ms feels instant.
  The results screen's push animation already takes about 0.35 s, so a median under
  300 ms still reads as a direct response, while anything over 500 ms reads as a
  pause on every search. Last query covers the whole path from tap to results on
  screen, not just ranking.
- **Memory, 300 MB.** The host peak is about 186 MiB for the whole Global pack. A
  device peak over 300 MB would mean the index or catalogue is held more than once,
  and it starts to risk background termination on older 4 GB iPhones.
