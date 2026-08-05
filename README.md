# Dive ID

Dive ID is an offline-first iOS prototype for written marine-life identification. The app processes text descriptions on device, ranks locally bundled species profiles, and stores saved identifications locally.

## Included Pack

### Caribbean Offline Identification Pack

* Pack ID: `caribbean`
* Pack version: 1
* 78 locally bundled species
* Species data and reference-image files ship in `DiveID/Resources/IdentificationPacks/Caribbean`.
* The pack focuses on common recreational-dive encounters in the broader Caribbean Sea and related tropical western Atlantic dive areas.

## Offline Behavior

* Species data ships with the app.
* Text-based vector reference markers ship with the app; binary image assets are intentionally not required by this repository.
* Descriptions stay on-device.
* Results require no internet.
* Saved identifications stay local.
* No account is required.
* Photo identification remains disabled and labelled as coming later.

## Catalogue Scope

The Caribbean pack is not a complete inventory of Caribbean marine life. It is a curated offline identification set for common diver and snorkeler encounters. Geographic occurrence varies by island, season, habitat, and subregion. Match strength is descriptive similarity against catalogue clues, not certainty, confirmation, probability, or scientific validation.

## Data and Image Sources

Species records include data-source metadata fields for taxonomy, range, size, depth, habitat, and visual-characteristic review. The current committed catalogue records source metadata in each profile. Image attribution is displayed from the bundled image metadata on species detail screens.

The repository intentionally avoids binary image files. Bundled artwork is stored as text SVG vector markers with visible attribution metadata; these are offline visual markers, not verified species photographs. If photographic references are added later, use public domain, CC0, or CC BY assets and verify licensing per image before shipping.

## Pack Versioning

Each pack has a JSON manifest with a stable machine-readable ID, schema version, pack version, display metadata, species count, species resource name, and image subdirectory. The bundle repository validates that the decoded species count matches the manifest count.

## Benchmark

A local Caribbean benchmark fixture contains 100 description cases with an approximate 70 development / 30 holdout split. It includes insufficient descriptions, out-of-region descriptions, ambiguous descriptions, juvenile/color clues, size clues, habitat clues, and common diver language. Full benchmark thresholds were not verified in this execution environment because Xcode was unavailable.

## Future Packs

The repository now uses a pack-oriented catalogue boundary and selected-region repository so future regional packs can be added. No downloadable pack system exists yet, and the app does not include download controls or remote pack updates.
