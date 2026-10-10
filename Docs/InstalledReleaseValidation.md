# Physical iPhone Release validation

This procedure supplements V05CandidateValidation.md. Current commit-bound outcome:
`Reports/InstalledReleaseValidation.json`. No real approval exists at that candidate;
stop positive Release testing until actual fingerprint-bound human decisions have
been applied and the regenerated publication subset is nonempty. Merging a source
review PR does not constitute record approval. Rebind this record to the new SHA
when that prerequisite changes. Never enable DEBUG or alter the evaluation.

## Capture and build on a Mac

Use a clean checkout of the approved candidate, a trusted, unlocked iPhone with
Developer Mode enabled, and the authorized signing account in Xcode. Do not delete
an existing app/container: historical saved data must survive an in-place update.
Use a dedicated test device/container and back it up before migration testing.

```bash
CANDIDATE_SHA='<approved candidate full SHA>'
test "$(git rev-parse HEAD)" = "$CANDIDATE_SHA"
test -z "$(git status --porcelain)"
EVIDENCE="$PWD/../diveid-device-$CANDIDATE_SHA"
mkdir -p "$EVIDENCE"
xcodebuild -version > "$EVIDENCE/xcode.txt"
xcodebuild -showsdks > "$EVIDENCE/sdks.txt"
xcrun devicectl list devices > "$EVIDENCE/devices.txt"
xcodebuild -project DiveID.xcodeproj -scheme DiveID -showdestinations > "$EVIDENCE/destinations.txt"
DEVICE_ID='<connected physical iPhone identifier>'
xcrun devicectl device info details --device "$DEVICE_ID" > "$EVIDENCE/device.txt"
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release \
  -destination "platform=iOS,id=$DEVICE_ID" -showBuildSettings -json \
  > "$EVIDENCE/release-settings.json"
```

Inspect resolved DiveID app settings before proceeding: bundle ID
`com.brycecameron.DiveID`, Automatic signing, team `7ZAXQ2686Z`, version 0.5,
build 2, iOS minimum 18.0. Record actual values rather than silently overriding
signing. If that team is unavailable, report signing blocked. Confirm DEBUG is
absent from active compilation conditions and all Swift/C preprocessor flags.
The shared Run scheme defaults to Debug; the explicit configuration below avoids it.

```bash
set -o pipefail
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -derivedDataPath "$EVIDENCE/derived-device" \
  -resultBundlePath "$EVIDENCE/device-build.xcresult" \
  build 2>&1 | tee "$EVIDENCE/device-build.log"
```

Stop installation if build fails. Do not disable signing, add DEBUG, or enable
testability for this device build. If provisioning is missing, resolve it in Xcode
with the authorized account; retain the original failure evidence. No archive,
export, upload or submission is part of this procedure.

```bash
APP="$EVIDENCE/derived-device/Build/Products/Release-iphoneos/DiveID.app"
plutil -p "$APP/Info.plist" > "$EVIDENCE/app-info.txt"
codesign -dv --verbose=4 "$APP" 2> "$EVIDENCE/signature.txt"
codesign -d --entitlements :- "$APP" > "$EVIDENCE/entitlements.plist" 2> "$EVIDENCE/entitlements.log"
find "$APP" -name '*.json' -exec shasum -a 256 {} \; > "$EVIDENCE/resource-hashes.txt"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" > "$EVIDENCE/install.txt"
xcrun devicectl device process launch --device "$DEVICE_ID" com.brycecameron.DiveID > "$EVIDENCE/launch.txt"
```

Inspect each packaged Creatures.json and PackManifest.json, comparing bytes to the
candidate resources. Count verified records with nonempty categories by pack;
check reviewer/date/provenance and manifest accounting with existing catalogue
validation. Packaged resources can contain drafts: publication access must exclude
them at runtime. Capture region picker/count/status screenshots and compare against
that verified subset. A source directory inventory is not packaged-resource evidence.

## Engine and unchanged cases

Release source selects `.productionDefault` = `.productionBM25`; the configured
engine dispatches to HybridDescriptionSearchEngine (BM25 candidate retrieval plus
biological ranking). Repository default is `.publication` outside DEBUG. Record
resolved settings, build log and installed binary identity. For runtime proof,
collect a symbolicated Instruments Time Profiler trace while searching and confirm
BM25SpeciesCandidateRetriever and biological ranking calls; if optimization prevents
identification, record runtime engine evidence as unverified, not inferred from a
UI label. Do not enable the experimental preference or change production defaults.

Use `DiveIDTests/Fixtures/V05Development.v2.json` verbatim. Join each case's
selectedPackID and expectedSpeciesIDs to that pack's verified IDs before running:
positive cases with no approved expected ID are inapplicable; keep their original
rank bounds. All original descriptions, splits and thresholds remain untouched.
Record case ID, exact text, pack/count, displayed species IDs/ranks, match strength,
expected outcome and screenshot/trace per trial. No-match, ambiguity and region
conflict probes require an available selected pack; otherwise mark blocked by
catalogue availability, not passed as no-match. The current record lists every case.

Run all applicable positives plus original regionConflict, out-of-domain/noMatch
and ambiguous probes. Distinguish a region mismatch from no match and a catalogue
loading failure. Try an unavailable region, return to an available region and retry;
if unavailable regions are disabled, record that behavior. Do not inject malformed
storage to manufacture an error. Verify results/detail/back preserves results and
switching available regions changes the active pack. Missing subset coverage is a
limitation, not permission to substitute draft species or easier descriptions.

## Persistence, offline operation and timing

Save a real result, capture its identity, force-close via app switcher, relaunch,
open Saved Identifications, reopen the sighting and confirm its snapshot. Remove,
force-close/relaunch and confirm removal. Before upgrading a dedicated prior-version
installation, save a sighting; install this candidate in place and reopen that
historical sighting, including a species absent from the new approved subset.
Preserve the original container backup. If no historical installation exists,
mark device migration unexecuted; fixture tests are separate evidence.

Disable Wi-Fi and cellular explicitly (Airplane Mode may retain Wi-Fi); record the
network state. Repeat the same applicable cases, save/relaunch and region recovery.
Record iPhone model, iOS build, Xcode/Instruments, SHA, installed version/build,
pack/count, engine evidence, thermal state and debugger attachment. Use timestamped
screen recording to measure Find Matches tap to stable results/no-match (state the
frame rate/resolution). Five cold trials each terminate/relaunch before first search;
20 warm trials keep the process running. OS disk caches are not claimed cold. Keep
raw samples and failures; report median and nearest-rank p95 separately per query
and region. Never use simulator or portable-test durations as iPhone measurements.

## Hosted tests are separate

Follow the independent build/unit/explicit packaging/UI commands in
V05CandidateValidation.md and `.github/workflows/ios-tests.yml`. After successful
build-for-testing, execute every test stage even if another fails, each with its
own log, exit status and xcresult. Record exact workflow SHA (PR merge SHAs may
differ), Xcode version, destination, counts and skipped tests. The existing hosted
workflow tests Debug on a simulator; its resolved Release settings check does not
prove an installed Release run. For optimized hosted tests use the separate Release
ENABLE_TESTABILITY=YES simulator build described there, never the device candidate.
Record build/unit/packaging/UI independently from manual device checks. Download
logs/result bundles before artifact expiry. A green hosted run cannot replace
physical iPhone, offline, persistence or latency evidence.
