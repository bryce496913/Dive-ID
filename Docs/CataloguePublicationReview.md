# Catalogue publication and first-review record

## Validation record (2026-09-24)

* Repository commit inspected before changes: `3503db8` (`work` branch).
* Environment: Linux x86_64 container. `xcodebuild` is unavailable, and no Mac,
  iPhone Simulator, or physical iPhone is attached. Consequently, the documented
  Xcode-hosted test, app-bundle proof, manual Debug searches, and device checks are
  **outstanding**. SwiftPM results below are portable evidence only and are not an
  equivalent substitute.
* Portable build configuration/destination: SwiftPM Debug,
  `x86_64-unknown-linux-gnu`.
* Actual search engine reported by the portable production-path fixture:
  `production-bm25-plus-biological-ranking`. The production BM25 default was not
  changed.
* Tropical Pacific bundle: manifest version 2, 384 structurally included records.
  Candidate recall was 4/4 at 10, 25, and 50. The versioned cases measured rank 1
  for ribbontail ray, rank 1 for dragon moray, and rank 1 for the short bluespotted
  ray description; fire dartfish, cockatoo waspfish, and blackspotted puffer missed
  their asserted bounds. The frog fixture correctly returned no match. Thus the
  existing positive-rank suite is not fully green and remains regression evidence,
  not production-quality validation.

## Publication accounting

| Pack | Structurally included | Human reviewed | Publication eligible | Debug searchable | Release searchable |
| --- | ---: | ---: | ---: | ---: | ---: |
| Caribbean | 8 | 0 | 0 | 8 | 0 |
| Tropical Pacific | 384 | 0 | 0 | 384 | 0 |

Debug explicitly uses experimental-development access. Release uses publication
access, so it currently has zero regions and zero searchable records. Release
identification is **not ready**. Import success, search benchmarks, and synthetic
test approvals cannot change those counts.

Manifest accounting is checked against decoded records during the normal catalogue
load and the raw loaded pack is cached. Missing or inconsistent accounting fails
closed. Publication labels distinguish zero, mixed, fully approved, and unavailable
accounting rather than treating an omitted count as approval.

## First review batch

`Reports/FirstCatalogueReviewBatch.json` contains 15 packets: all eight Caribbean
records and these seven importer-identified Tropical Pacific records with unresolved
category OCR:

| Stable ID | Record | Source book / PDF page | Source tile | Unreadable source category |
| --- | --- | --- | --- | --- |
| `2236afd6-7658-5782-b578-3985f74beffd` | Barred Shrimpgoby | 305 / 306 | bl | `Gctblee` |
| `490d41af-6fe3-5ee5-90c1-8db7343bd488` | Roundbelly Cowfish | 393 / 394 | ml | `Boxitihias` |
| `f0c4bc22-176d-5de0-bad0-ec82eb76787b` | Sulu Fangblenny | 340 / 341 | br | `} Blomiiivs` |
| `a1cd00fe-6e62-5abd-b138-da65a9d42b45` | Striped Fangblenny | 341 / 342 | ml | `Bioruies` |
| `a388889a-8816-5616-9b14-7b606e7a7137` | Lined Fangblenny | 341 / 342 | mr | `Bigunics` |
| `c4297488-0a9f-5834-b2b1-252884d3522d` | Skinspot Dwarfgoby | 328 / 329 | br | `Golsios` |
| `5e1834f8-29c2-543a-b5d3-e5d42e264a40` | Estuarine Halfbeak | 135 / 136 | mr | `Haifheake` |

Each packet includes stable and source-row identity, current identification fields,
source URLs and page locators, original imported text, correction slots, unresolved
questions, field evidence, decision fields, and a reviewed-content fingerprint.
The repository has the workbook transcription and page/tile locators but does not
contain the original source PDF pages. Therefore no category correction was inferred
from a garbled heading or species name. A reviewer must obtain and inspect those
specific pages. All 15 decisions remain draft, with no reviewer or review date.

`Data/CatalogReview/ReviewDecisions.json` is the durable decision overlay. The
Tropical Pacific importer reapplies matching decisions after every import. The small
review tool can apply the same overlay to another pack. A decision is applied only
when its stable source identity and post-correction content fingerprint match;
material changes become stale. Verified decisions with unresolved questions or an
empty category are blocked. The overlay's `catalogueID` must match the target pack,
and each species may occur only once. Decisions use `draft`, `sourceChecked`, or
`verified`; a verified decision requires a nonblank reviewer identity and notes, a
UTC review date in `YYYY-MM-DDTHH:MM:SSZ` format, and the complete source evidence
required by the app's catalogue validator. The complete overlay and both generated
outputs are validated before either catalogue file is safely replaced. The tool then regenerates structurally included,
human-reviewed, and publication-eligible counts separately.

## Saved identifications

Saved records embed the species and match evidence and the saved-detail route opens
that stored snapshot without resolving it through the new-search catalogue. The
Release publication filter therefore does not remove historical access or make a
saved draft eligible for a new search. IDs and the saved schema were not changed, so
no migration is required. The established Xcode compatibility suite remains the
hosted proof and is outstanding in this Linux environment.
