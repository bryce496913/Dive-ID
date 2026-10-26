# Installed-app validation on a physical iPhone (2026-10-25)

This record replaces the unexecuted rows of `DeviceValidation-2026-10-24.md`. The raw
records are in `Reports/DeviceValidation.2026-10-25.json`. Physical-device, simulator
and automated results are kept apart below.

## Candidate and device

| Field | Value |
| --- | --- |
| Source | `00585dc` plus this commit's fixes (`DescriptionSearch.swift`; the Debug/Internal strip cap does not reach Release). The keyboard fix was found by this validation; every row below was re-run on the final build |
| Configuration | Release, built with `xcodebuild -configuration Release` for `iphoneos`, automatic signing, team `7ZAXQ2686Z` |
| App | `com.brycecameron.DiveID` 0.5 (2); executable SHA-256 `48db9e107aa5873b…` (full value in the report). The previous build `38724975…` passed the same rows; the offline hand check below was done on it |
| Product check | `Tools/CI/validate_device_release.py` passed: signed iPhoneOS Release, no DEBUG, no testability, no internal diagnostics, no semantic artifacts |
| Catalogue | Global 4,798 bundled / **4,796 searchable** (drafts Graceful shark and Silky shark excluded); Caribbean 8 / 2; Tropical Pacific 1,000 / 0. Packaged IDs equal the approvals oracle |
| Search engine | `productionBM25`; Release has no experimental switch or diagnostics |
| Device | iPhone 14 Pro (iPhone15,2), iOS 27.0.1 (24A446), USB |
| Tools | Xcode 26.5 (17F42), macOS 26.5 (25F71) |

## Radios: what ran offline

- **Automated rows ran with Wi-Fi on and cellular off.** xcodebuild reinstalls the
  developer-signed test runner on every run, and iOS 27 refuses to launch a new
  developer-signed install until it can verify the certificate online ("Developer App
  Certificate is not trusted"). Dive ID itself launched offline; only the runner could not.
- **Manual offline check, Airplane Mode on, Wi-Fi and cellular off,** performed by the
  device owner on build `38724975…`, which differs from the final build only in when the
  Done button is added to the navigation bar. All seven steps were as expected: Global search
  (Spotted Eagle Ray #1), Find Matches with the keyboard open, editing and searching again
  with the keyboard open, the no-match state, save → force-quit → relaunch → reopen with
  the description shown, remove → relaunch → gone, and the largest text size.

The app makes no network requests, but the timings below were measured online and are
not claimed as airplane-mode timings.

## Expected versus observed (physical iPhone, Release, BM25)

| # | Check | Observed | Result |
| --- | --- | --- | --- |
| D1 | Fresh install opens in Global, 4,796 species, Photo disabled | Global shown on Home in all 5 fresh installs; offline check confirmed 4,796 and "Coming later" | pass |
| D2 | First and repeated searches | First result Spotted Eagle Ray (`…0010`) in all 5 fresh, 5 later and 20 warm searches | pass |
| D3 | Positive / region conflict / ambiguous / no-match (Caribbean) | Atlantic Blue Tang rank 1; Fiji description gives the region-mismatch failure, no Try Again; ambiguous angelfish top label "Weak match"; both no-match texts give the empty state, not an error | pass |
| D4 | Find Matches with the keyboard open | Button wholly above the keyboard through 10 lines of text; five search → back → edit → search rounds with the keyboard open, the button stays at y 462–516 and every tap searches | pass after fix (see Defect) |
| D5 | Largest text size | Offline hand check: Find Matches reachable and searching | pass (manual) |
| D6 | Results → detail | Each of the first three results opened its own species (Spotted Eagle Ray, Blonde ray, Spotted ray); back showed the same results without a new search | pass |
| D7 | Region switching | Global top result, then Caribbean through the UI; Caribbean results only its two approved species; choice kept after relaunch | pass |
| D8 | Unavailable selected region | Debug build installed, Tropical Pacific selected, Release installed in place: "Dive region unavailable" shown, Global selected, kept after relaunch | pass |
| D9 | Cancel then search again (×10, every third with background/foreground) | The newer no-match search always showed the empty state and stayed after 2 s. **Cancellation was not observed**: each abandoned search had already finished (about 0.8 s) when the test went back | pass, cancellation not observed |
| D10 | Save → terminate → relaunch → reopen | Saved row present after relaunch; reopened detail shows the original description and, in Habitat and range, region Global | pass |
| D11 | Remove → relaunch | "No saved identifications" after relaunch | pass |
| D12 | UI never blocks | Longest gap between accessibility snapshots, which the main thread serves, while the index built during a fresh-install first search: 0.19 s median, 0.27 s worst (5 runs); 0.07 s worst in the warm series | pass |

## Timing (physical iPhone, Release, Wi-Fi on)

Measured by XCUITest on the phone: the clock starts just before the launch or tap and
stops at the first accessibility snapshot showing the end state. The snapshot interval
(reported) is the resolution. Fresh install means uninstall then install before each
trial; OS file caches are not cleared, so nothing is claimed as truly cold.

| Measure | n | Median | Range / p95 |
| --- | --- | --- | --- |
| Launch → enabled Describe, fresh install | 5 | 1.75 s | 1.63–1.98 s |
| Describe → editor ready | 10 | 0.90 s | 0.88–0.93 s |
| Launch → enabled Describe, later launch | 5 | 2.63 s | 2.55–2.74 s |
| First query, fresh install (index built) | 5 | 6.23 s | 5.88–6.54 s |
| First query, later launch (archive loaded) | 5 | 0.89 s | 0.87–1.06 s |
| Warm query, one process | 20 | 0.79 s | nearest-rank p95 0.93 s |

The previous build gave the same picture (fresh first query 6.15 s, later 0.87 s, warm
0.76 s / p95 0.90 s); both series are in the report.

Later launches reach Describe about 0.9 s later than fresh installs; they load the index
archive, while a fresh install builds the index after the first search starts.

## Defect found and fixed

On iOS 27, after two returns from Possible Matches, Find Matches moved 48 pt down
(y 448 → 496) and sat under the keyboard's suggestion bar, so a tap hit the keyboard.
The navigation bar and the keyboard's Done button stayed put; only the content moved by
the height reserved for the keyboard toolbar. Done now sits in the navigation bar while
the editor has focus, and the keyboard toolbar is gone. The button stays in the bar and is
only hidden while the editor is unfocused: adding it on focus could drop the focus that had
just arrived on the iOS 26.5 simulator. The new device test
`testFindMatchesWorksWithKeyboardAfterReturningFromResults` failed on the old build in
round 3 and passes all five rounds on the fixed build.

## Experimental semantic check (Debug, separate from Release)

A Debug build with the genuine `Semantic-global` artifacts (see
`RealEncoderLocalValidation-2026-10-25.md`), launched with
`-DiveIDExperimentalSemanticSearch YES`:

| Case (Global) | Requested / actual engine | Fallback | Result | Time |
| --- | --- | --- | --- | --- |
| Positive (query G) | Core ML semantic + BM25 / Core ML semantic + BM25 | none | Spotted Eagle Ray #1 | 13.5 s (first search: model load and index) |
| Ambiguous ("Dark angelfish near a reef.") | same / same | none | 10 results, Spotted Eagle Ray #3 (a semantic-only addition) | 1.7 s |
| No-match (freshwater frog) | same / same | none | empty state | 1.2 s |

Release keeps BM25 and has no way to select this.

## Running the device tests (Xcode 26.5, iOS 27)

Xcode 26.5 cannot launch a UI-test target app on iOS 27 (CoreDeviceError 10004, "process
identifier … could not be determined"). The tests address Dive ID by bundle identifier,
and the generated `.xctestrun` is edited so the target app is the runner itself, which
makes XCTest launch Dive ID through the device's test daemon:

```bash
B=DiveIDDeviceValidation-notarget.xctestrun; cp "$PRODUCTS"/DiveIDDeviceValidation_*.xctestrun "$PRODUCTS/$B"
for k in UITargetAppEnvironmentVariables UITargetAppCommandLineArguments \
         UITargetAppPerformanceAntipatternCheckerEnabled DependentProductPaths:0; do
  /usr/libexec/PlistBuddy -c "Delete :DiveIDUITests:$k" "$PRODUCTS/$B"; done
/usr/libexec/PlistBuddy -c "Set :DiveIDUITests:UITargetAppPath __TESTROOT__/Release-iphoneos/DiveIDUITests-Runner.app" "$PRODUCTS/$B"
TEST_RUNNER_DIVEID_DEVICE_VALIDATION=1 TEST_RUNNER_DIVEID_DEVICE_PHASE=later-launch \
  xcodebuild test-without-building -xctestrun "$PRODUCTS/$B" -destination "platform=iOS,id=$DEVICE_ID" \
  -only-testing:DiveIDUITests/DeviceValidationUITests/testWarmQueryLatency
```

Build the runner with a per-user scheme holding only `DiveIDUITests`: Release cannot build
the unit-test target. Install Dive ID yourself with `xcrun devicectl device install app`.
Set Auto-Lock to Never; a locked phone fails the run.

## Largest text size and CI destinations (simulator evidence, not device evidence)

Review finding: at the largest text size Find Matches sat above the keyboard but was not
hittable, on the iPhone SE. Cause: the Debug-only diagnostics strip grew with Dynamic Type
to about 280 pt, squeezed the Describe screen, and covered the button. Its touches were
already ignored, but its texts are accessibility elements, so XCUITest reported the button
as covered. Release has no strip, so the iPhone results above are unaffected. Fixes in this
commit:

- The strip's text size is capped at Large in Debug and Internal.
- The hosted UI tests wait until Describe is enabled, bring tall elements into view, and
  let scrolling and transitions settle before tapping. Taps sent during scroll momentum
  or a push transition were being dropped. No assertion was removed or loosened.

Local runs, Xcode 26.5, iOS 26.5 simulators, `-parallel-testing-enabled NO`:

| Destination | Window | Smoke | Keyboard | Keyboard, largest text | Layouts, largest text | New install / Photo |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone 17 Pro | 402 × 874 | pass | pass | pass (button 452–531, keyboard from 583) | pass | pass |
| iPhone SE (3rd generation) | 375 × 667 | **fail** (first test after install) | pass | pass (button 320–399, keyboard from 451) | pass | pass |

The remaining SE smoke failure is the first test after a fresh simulator install: Describe
is enabled and still, the tap is sent, and the screen does not change. It did not happen on
the iPhone, where all fresh installs opened Describe on the first tap. It is not yet
explained and is not marked as passing.

CI (`ios-tests.yml`) now fails unless an iPhone SE simulator exists that differs from the
main one, always runs the SE pass, and checks from the logged `UIDIAG window=` sizes that the
two passes ran on different screens. The main destination already excluded the SE.
