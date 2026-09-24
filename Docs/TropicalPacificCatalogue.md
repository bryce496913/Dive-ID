# Tropical Pacific catalogue

The pack is generated from all 1,650 creature rows in `DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx`; do not hand-edit its JSON or reports. Run:

```sh
python3 -m pip install -r Tools/CatalogImport/requirements.txt
python3 Tools/CatalogImport/import_tropical_pacific.py
```

## Inclusion and outcomes

There is no numeric pack limit. A row is bundled only when it has workbook-supported regional presence, a complete high-confidence printed identity (score 100), high-confidence account transcription, a high-confidence identification description, a source ID and locator, and names unique within the loadable pack. The first 40 records under the former page/UUID ordering are recorded as a regression baseline in the report. The complete eligible set is sorted deterministically for the app and described in deterministic batches of 100 in the report.

Every row has exactly one outcome in `Reports/TropicalPacificOutcomes.csv`: `included`, `pending_review`, or `excluded`, with explicit reasons and source/OCR/confidence evidence. `Reports/TropicalPacificReviewQueue.csv` contains unresolved rows plus included draft rows carrying the workbook review flag, so likely OCR and identity conflicts—including baseline records—remain visible for source-page review. An included row means it is structurally safe to load, not that its identity has been verified.

Unsupported fields are null/empty. `scientificName` is explicitly the source-printed identity needed by the current search model; `taxonomy` remains null, so it is not silently promoted to an accepted name. Maximum size is kept only in the maximum-size field; `measurements` is null because the workbook does not establish a measurement type or typical observed size. Supported presence is represented by `regionalOccurrence = unknown`, because presence is not evidence of regular abundance. Aliases, cautions, comparisons, structured body/head/fin claims, reviewers, AphiaIDs, and taxonomy are not invented. All generated reviews remain `draft`.

Workbook group classifications are translated to the ranker's controlled categories by an explicit, case-insensitive, whitespace-normalized allow-list. Most named fish groups (for example, `Butterflyfishes` and `Damselfishes`) become `fish`; the ranker's existing `eel`, `seahorse`, `shark`, and `ray` categories remain distinct. Exact matching is deliberate, so unrelated names ending in “fish” and OCR-corrupted or unknown classifications are not guessed. The original classification, resolved category, and any diagnostic remain in the outcome report; aggregate mappings and unresolved values are recorded in the JSON report.

The workbook's book-scan photographs are `reference_only_not_licensed_for_app`; the importer deliberately reads no Media rows and creates no image records. The existing image-less placeholder therefore remains the presentation.

`Reports/TropicalPacificImportReport.json` records outcome counts, all bundled UUIDs, the 40-ID baseline, reproducible batches, and media/schema policies. Output contains no current timestamp. Rerunning the importer must produce byte-identical files.

## Evaluation scope

`TropicalPacificCatalogueTests` exercises independently written positive, ambiguous, vague, and genuine no-match text. It reports candidate recall at 10, 25, and 50 and prints displayed top-1/top-3/top-10 results through `LocalMarineLifeIdentificationService`. It also includes a bundle-only repository test: the Xcode test host must load the production app resource rather than a source path. These are catalogue/search regression evidence, not a claim of production identification quality. The frozen Caribbean holdout is neither read nor tuned by the importer.

## Mac validation pass

Linux can run `swift test` and importer checks, but cannot prove Xcode resource placement, resolve an Xcode build setting, install an iOS app, or measure a physical device. Run the following from a clean checkout on a Mac. Keep the simulator and device paths separate: an `iphoneos` app cannot be installed in Simulator, and an `iphonesimulator` app cannot be installed on an iPhone.

The project setting is `com.brycecameron.DiveID`. Verify the **resolved** value for the exact configuration and destination rather than copying that text into an install script:

```sh
set -euo pipefail
PROJECT=DiveID.xcodeproj
SCHEME=DiveID
CONFIGURATION=Debug
BUNDLE_ID="$({ xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" -sdk iphonesimulator -showBuildSettings || exit 1; } \
  | awk -F ' = ' '/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER = / { print $2; exit }')"
test "$BUNDLE_ID" = com.brycecameron.DiveID
printf 'resolved bundle identifier: %s\n' "$BUNDLE_ID"
```

Use `Debug` for this validation. Every generated Pacific record currently has review status `draft`; explicit experimental-development catalogue access exposes all 384 structurally included records and supplies debug-only reporting of the actual retrieval engine and fallback. Publication access (the `Release` default) filters to records carrying complete, traceable human-review evidence. The current Pacific pack has zero publication-eligible records, so it is omitted from ordinary Release catalogue choices and an explicit request fails with `CATALOG_PUBLICATION_UNAVAILABLE`; it is never replaced by Caribbean or treated as approved because parsing/search tests passed. Release also fixes retrieval to the production BM25 default and omits the debug diagnostics UI. Do not change ranking, thresholds, or engine selection for this pass.

### Simulator: build, test, install, and launch one exact product

Choose one available iPhone simulator UDID and use it in every command. This example selects the newest available iOS 18-or-later iPhone, boots that device, uses a simulator-only DerivedData directory, builds tests once, runs the complete hosted catalogue/search class without rebuilding, then installs the exact Debug simulator product:

```sh
set -euo pipefail
PROJECT=DiveID.xcodeproj
SCHEME=DiveID
CONFIGURATION=Debug
SIM_DERIVED="$PWD/.derived-validation/simulator-debug"
SIM_UDID="$({ xcrun simctl list devices available --json || exit 1; } | python3 -c '
import json, re, sys
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"iOS[- ](\d+)[-.](\d+)", runtime)
    if not match or int(match.group(1)) < 18:
        continue
    version = tuple(map(int, match.groups()))
    candidates += [(version, d["name"], d["udid"]) for d in devices
                   if d.get("isAvailable") and d.get("name", "").startswith("iPhone")]
if not candidates:
    raise SystemExit("No available iOS 18+ iPhone simulator was found")
print(sorted(candidates, reverse=True)[0][2])
')"
DESTINATION="platform=iOS Simulator,id=$SIM_UDID"
rm -rf "$SIM_DERIVED"
xcrun simctl bootstatus "$SIM_UDID" -b

xcodebuild -version
xcrun simctl list devices | sed -n "/$SIM_UDID/p"
git rev-parse HEAD
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" -destination "$DESTINATION" \
  -derivedDataPath "$SIM_DERIVED" CODE_SIGNING_ALLOWED=NO build-for-testing
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" -destination "$DESTINATION" \
  -derivedDataPath "$SIM_DERIVED" CODE_SIGNING_ALLOWED=NO test-without-building \
  -only-testing:DiveIDTests/TropicalPacificCatalogueTests

SIM_APP="$SIM_DERIVED/Build/Products/Debug-iphonesimulator/DiveID.app"
test -d "$SIM_APP"
test -f "$SIM_APP/IdentificationPacks/TropicalPacific/PackManifest.json"
test -f "$SIM_APP/IdentificationPacks/TropicalPacific/Creatures.json"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SIM_APP/Info.plist")
test "$BUNDLE_ID" = com.brycecameron.DiveID
xcrun simctl install "$SIM_UDID" "$SIM_APP"
xcrun simctl launch --console "$SIM_UDID" "$BUNDLE_ID"
```

The class run includes both `testProductionRepositoryLoadsTropicalPacificFromBuiltApplicationBundle` (the hosted packaged-resource proof) and `testVersionedDiverDescriptionsThroughProductionIdentificationService` (the production BM25-plus-biological-ranking search path). Preserve its `PACIFIC_DESCRIPTION_CASE` and candidate-recall output in the validation record. To reproduce CI's broader coverage from the same build, additionally run `test-without-building -only-testing:DiveIDTests`; do not reuse this DerivedData directory for a device build.

### Physical iPhone: signed device product and supported install path

Connect and trust the iPhone, enable Developer Mode, and obtain its CoreDevice identifier from `xcrun devicectl list devices`. Set `DEVICE_ID` explicitly; do not use `generic/platform=iOS`, which cannot identify the hardware used for the record. Automatic signing uses the project's configured development team, but the Mac must have a valid account/certificate/profile for the connected device.

```sh
set -euo pipefail
PROJECT=DiveID.xcodeproj
SCHEME=DiveID
CONFIGURATION=Debug
DEVICE_ID='<paste the connected device identifier from devicectl>'
DEVICE_DESTINATION="platform=iOS,id=$DEVICE_ID"
DEVICE_DERIVED="$PWD/.derived-validation/device-debug-$DEVICE_ID"
rm -rf "$DEVICE_DERIVED"

xcodebuild -version
xcrun devicectl list devices
git rev-parse HEAD
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" -destination "$DEVICE_DESTINATION" \
  -derivedDataPath "$DEVICE_DERIVED" -allowProvisioningUpdates build
DEVICE_APP="$DEVICE_DERIVED/Build/Products/Debug-iphoneos/DiveID.app"
test -d "$DEVICE_APP"
test -f "$DEVICE_APP/IdentificationPacks/TropicalPacific/PackManifest.json"
test -f "$DEVICE_APP/IdentificationPacks/TropicalPacific/Creatures.json"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEVICE_APP/Info.plist")
test "$BUNDLE_ID" = com.brycecameron.DiveID
xcrun devicectl device install app --device "$DEVICE_ID" "$DEVICE_APP"
xcrun devicectl device process launch --device "$DEVICE_ID" --console "$BUNDLE_ID"
```

Run `build-for-testing`/`test-without-building` against a physical-device destination only if the device and signing setup support hosted tests; use a third, device-test-specific DerivedData directory and the same two Xcode actions shown in the simulator section. The simulator run is the required hosted catalogue/search test path and does not require signing.

### Manual search and offline checks

In the Debug app select the **Tropical Pacific** pack (pack version 2, 384 records) and use the positive descriptions from `DiveIDTests/Fixtures/TropicalPacificDiverDescriptions.v1.json`. Expected IDs and acceptable displayed ranks are:

| Fixture case | Expected species ID | Acceptable rank |
| --- | --- | ---: |
| `pacific-v1-ribbontail-ray` | `50020f47-9605-5ed9-bb79-7a2e43db22b9` | 1–3 |
| `pacific-v1-dragon-moray` | `042f8722-88e3-5fc2-8f26-66d00b546730` | 1–3 |
| `pacific-v1-fire-dartfish` | `7a662be3-854f-5819-8d32-cb8b1f19a00b` | 1–5 |
| `pacific-v1-cockatoo-waspfish` | `5f4d48f4-6556-50f3-95af-a4d28635f4bb` | 1–5 |
| `pacific-v1-blackspotted-puffer-short` | `3994805f-494f-5c71-9f2f-7105615c6a27` | 1–10 |
| `pacific-v1-bluespotted-ray-short` | `50020f47-9605-5ed9-bb79-7a2e43db22b9` | 1–5 |

These bounds deliberately do not promise an undocumented exact ordering. Also enter the fixture's frog description and verify that it produces no match. Before testing, leave `DiveIDExperimentalSemanticSearch` disabled. Record the debug status as requested engine, **actual** engine, and fallback reason; the expected production path is `productionBM25`, with no fallback. A different observation must be reported, not hidden by switching engines.

After one online search, terminate the app, disable the Mac/iPhone's Wi-Fi and cellular/network connection, relaunch it, select the same pack, and repeat at least one positive search plus the no-match search. Record pass/fail and any fallback. Simulator timing is only a simulator observation and must be labelled as such. Measure cold pack load, search latency, and peak memory with Instruments (`Time Profiler` and `Allocations`) **only on actual connected hardware**; if hardware is unavailable, write `physical-device latency: not measured (no hardware)` rather than substituting or inventing a number.

### Validation record

Attach the command log and fill in every field (use `not run`/`not available` rather than inference):

```text
commit:
configuration: Debug
Xcode version/build:
host macOS version:
destination type: iOS Simulator | physical iPhone
device/simulator model and identifier:
iOS version:
DerivedData path:
resolved bundle identifier:
installed app path:
active pack: tropical-pacific
pack version / manifest count / loaded count: 2 / 384 /
requested retrieval engine:
actual retrieval engine:
fallback reason (none if absent):
build-for-testing result:
hosted packaged-catalogue test result:
catalogue/search fixture test result and measured ranks:
offline relaunch/search result:
simulator observations (not device performance):
physical-device cold-load/search latency and peak memory, or not measured reason:
```

No performance numbers are claimed by this document. This validation does not change the production search engine, approve the experimental Core ML model, or publish draft records.
