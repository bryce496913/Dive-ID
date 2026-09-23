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

## Mac/device validation pass

Linux can run `swift test` and importer checks, but cannot prove Xcode resource placement or on-device performance. On a Mac, run:

```sh
xcodebuild -project DiveID.xcodeproj -scheme DiveID -destination 'platform=iOS Simulator,name=iPhone 16 Pro' test
xcodebuild -project DiveID.xcodeproj -scheme DiveID -configuration Release -destination 'generic/platform=iOS' -derivedDataPath .derived build
find .derived/Build/Products -path '*DiveID.app/IdentificationPacks/TropicalPacific/*' -print
xcrun simctl install booted .derived/Build/Products/Release-iphonesimulator/DiveID.app
xcrun simctl launch --console booted com.diveid.app
du -sh .derived/Build/Products/Release-iphoneos/DiveID.app
```

Use Instruments (`Time Profiler`, `Allocations`) on that Release build to record cold pack load, description-search latency, peak memory, and offline behavior. Exercise both regions, save and reopen an identification, disable networking, and repeat a Tropical Pacific search. No performance numbers are claimed until that pass is run. This import does not change the production search engine and does not approve the experimental Core ML model.
