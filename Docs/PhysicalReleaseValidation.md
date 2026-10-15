# Physical Release validation

Status on October 14, 2026: **unexecuted**. The available executor is Linux;
Xcode, a paired physical iPhone and a remote Mac are unavailable. No installed
app, offline result, latency, memory or responsiveness observation is claimed.
`Reports/PhysicalReleaseValidation.json` separates expectations from observations.

## Candidate and signing

Use the final PR commit, not an uncommitted workspace. The application content
baseline is main `10af439db9dc4d3e160a2f9bb0432d4fb2a80ea3`, version 0.5/build 2,
iOS 18 minimum. Record the actual candidate SHA below when executing. Project
settings currently specify team `7ZAXQ2686Z` and bundle ID
`com.brycecameron.DiveID`; derive the identifier from resolved settings rather
than assuming these values. Use an authorized signing account with a provisioned,
trusted iPhone and Developer Mode enabled. Do not disable signing or install a
simulator product. No distribution is authorized by this procedure.

Run from a clean repository checkout on the Mac, in bash. Choose the physical
device ID listed by Xcode and devicectl. Use a new output directory per run.
Do not uninstall the app between persistence checks or overwrite an unreadable save.

```bash
set -euo pipefail
DEVICE_ID='<connected physical iPhone identifier>'
OUT="$(mktemp -d /tmp/diveid-physical-release.XXXXXX)"
cp Reports/PhysicalReleaseValidation.json "$OUT/device-observations.json"
git rev-parse HEAD > "$OUT/candidate-sha.txt"
git status --porcelain > "$OUT/working-tree.txt"
test ! -s "$OUT/working-tree.txt"
xcodebuild -version | tee "$OUT/xcode-version.txt"
xcrun devicectl list devices --json-output "$OUT/devices.json"
xcrun devicectl device info details --device "$DEVICE_ID" --json-output "$OUT/device.json"
DEST="platform=iOS,id=$DEVICE_ID"
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release \
  -destination "$DEST" -derivedDataPath "$OUT/derived-device" \
  -showBuildSettings -json > "$OUT/settings.json" 2> "$OUT/settings.log"
python3 - "$OUT/settings.json" <<'PY'
import json, sys
from Tools.CI.validate_device_release import validate_settings
validate_settings(json.load(open(sys.argv[1])))
PY
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release \
  -destination "$DEST" -derivedDataPath "$OUT/derived-device" \
  -resultBundlePath "$OUT/build.xcresult" build 2>&1 | tee "$OUT/build.log"
APP=$(python3 - "$OUT/settings.json" <<'PY'
import json, sys
s=next(x['buildSettings'] for x in json.load(open(sys.argv[1])) if x['target']=='DiveID')
print(s['TARGET_BUILD_DIR']+'/'+s['FULL_PRODUCT_NAME'])
PY
)
python3 Tools/CI/validate_device_release.py --settings "$OUT/settings.json" \
  --app "$APP" --output "$OUT/product-check.json"
codesign --verify --deep --strict "$APP" 2>&1 | tee "$OUT/signature.log"
codesign -d --entitlements :- "$APP" > "$OUT/entitlements.plist" 2> "$OUT/signing.txt"
APP_BUNDLE_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["bundleIdentifier"])' "$OUT/product-check.json")
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" \
  --json-output "$OUT/install.json"
xcrun devicectl device info apps --device "$DEVICE_ID" --json-output "$OUT/installed-apps.json"
xcrun devicectl device process launch --device "$DEVICE_ID" "$APP_BUNDLE_ID" \
  --json-output "$OUT/launch.json"
printf 'Evidence directory: %s\n' "$OUT"
```

If signing fails, resolve that account/profile/device issue in Xcode and rerun
in a new directory. Do not work around it with `CODE_SIGNING_ALLOWED=NO`. Never
define DEBUG, inject experimental settings, or enable testability in this product.
The checker verifies full packaged catalogue content (drafts remain bundled),
then verifies the eligible ID set against valid decisions. The installed app must
expose only those eligible IDs; packaged drafts alone are not a gate failure.
Fill the copied device-observations.json with the actual installed SHA, device
details, observed rows and timing samples; retain the checked-in unexecuted record
as the preparation baseline. Attach evidence paths instead of replacing expectations.

## Expected versus observed on the phone

Expected Release: Caribbean available, exactly two approved species; Pacific
unavailable. Atlantic Blue Tang ID `00000000-0000-0000-0000-000000000003`;
Queen Angelfish ID `fc213eff-6ba6-53ab-b288-f6e654299e68`. All 390 drafts excluded.
Source inspection confirms the Release app selects `.productionDefault`
(`productionBM25`); the experimental preference is compiled only under DEBUG.
For runtime evidence, retain an Instruments call-tree trace showing
`BM25SpeciesCandidateRetriever` and `LocalSpeciesRanker` during a search. Check
symbols/dSYMs from this product if needed. A UI label or successful search alone
does not establish actual engine execution. If unobservable, mark it unverified.

1. Record phone model, iOS version/build, app version/build, signed bundle ID,
   installed product path and SHA. Preserve install receipt and screenshots of
   region counts/status and both species' details/source labels. Verify no photo
   identification or semantic inference is presented as functional.
2. Enable airplane mode, then explicitly turn Wi-Fi and cellular data off in
   Settings (Control Center disconnection alone is insufficient). Record settings
   screenshots and keep these settings throughout searches, saves and relaunches.
3. Select Caribbean; enter each case below exactly as stored in the frozen
   `DiveIDTests/Fixtures/V05Development.v2.json`. Record ordered returned species,
   displayed rank, match-strength text, no-match/mismatch outcome and screenshot.
   These descriptions are synthetic development probes, not independent divers.
4. To test persisted unavailable-region recovery on a dedicated test installation,
   first use Debug with the same bundle identifier to select Pacific, then install
   this Release build over it without uninstalling. Home must say “Selected region
   unavailable”, offer Change Dive Region, allow Caribbean selection and search,
   and persist Caribbean after relaunch. It must not claim no reviewed catalogue
   exists anywhere. Pacific stays unavailable. No second approved region currently
   exists. Do not use a launch-argument defaults override as proof of persistence.
5. Start a search, immediately back out, then submit a different case. Repeat ten
   times; the latest request's results/region must win, without stale replacement
   or a stuck spinner. Two records may finish before navigation: record that as
   cancellation not observed, not a pass for in-flight cancellation. Controlled
   async automated tests supply separate evidence. Open details/back and verify
   cached results; complete 30 flows, then background/foreground on each screen.
6. Save a result. Force-close from the app switcher, relaunch from the icon, open
   Saved Identifications and the saved detail. Remove it, force-close/relaunch,
   confirm absence. Open any preexisting historical snapshot even if its species
   is excluded from new searches. If none exists, mark that manual check unexecuted;
   automated historical-fixture results do not replace a device observation.

| Frozen case | Exact description | Expected on this subset |
| --- | --- | --- |
| v05-01-diagnostic | Compressed blue reef fish with a yellow spine beside its tail. | Blue Tang rank ≤3 |
| v05-01-paraphrase | Yellow juvenile surgeonfish grazing on the Caribbean reef. | Blue Tang rank ≤10 |
| v05-ambiguous-angelfish | Dark angelfish near a Caribbean reef. | Conservative ambiguity; only eligible Queen may match; confidence ≤0.64 |
| v05-caribbean-vague | A fish moved past me. | No match |
| v05-caribbean-terrestrial | A spotted freshwater frog on sand, about 5 cm long. | No match |
| v05-region-1 | Blue and yellow striped surgeonfish on a reef in Fiji. | Region mismatch, not wrong-pack results |

Also run both `v05-03-*` Queen cases directly from the frozen fixture; preserve
their original ranks and wording. Cases targeting unavailable species are
inapplicable to this installed subset, not relaxed versions of the full evaluation.
Record each manual row as pass/fail/unexecuted with expected/observed/evidence.

## Timing protocol

Use the same positive case (`v05-01-diagnostic`), Caribbean/2 eligible records,
Release BM25+biological ranking, no attached debugger, stable thermal state and
the same recording method. Record first-search trials separately: five process
termination/relaunch trials, first search after each launch (OS filesystem caches
are not claimed cold). Then collect 20 searches in one running process as warm
trials. Boundaries: Find Matches tap to stable rendered results/no-match state.
Use timestamped screen video with frame rate recorded; retain start/end frame
numbers and raw milliseconds. These are end-to-end timings, not ranker duration.

For each group report sample count and median; for 20 warm successes report p95
as sorted sample `ceil(0.95*n)` (one-based). Five first-search samples are too few
for a stable tail estimate: report median/range, no p95 claim. Keep errors/timeouts
as separate failed trials, never zero timings or silently discarded samples.
Record visible hangs, scrolling responsiveness and background recovery separately.
Optional memory evidence must specify Instruments physical-footprint metric,
sampling interval, baseline/peak/settled readings; no estimates from session counts.

## Separate automated evidence

Run `python3 -m unittest discover -s Tools/CI -p 'test_*.py' -v` and the existing
catalogue review/reproducibility checks. Run `swift test -c release --jobs 4` for
portable publication, lifecycle, persistence and frozen service-path evaluation.
Use V05CandidateValidation.md for separate simulator build-for-testing, full unit,
packaging and UI stages; all must run independently after successful build.
Keep device derived products, logs and `.xcresult` bundles separate from simulator
products. Passing these suites is not physical-device or offline-radio evidence.
