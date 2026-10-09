# Catalogue publication and source-review record

## Current pass — 2026-10-09

Baseline: main `d031795d5414bb6e3c9d47148a1ccb4d0d5c3243` (PR #83 merged).
No applicable AGENTS.md was found. This pass inspected accessible source pages;
it did not obtain human approval. Actual approved IDs: **none**. Caribbean remains
8 draft / 0 reviewed / 0 publication eligible; Pacific remains 384 / 0 / 0.
Release publication access therefore correctly offers no region or search records.

The three Caribbean accounts selected in the existing review handoff now have
accessible original FishBase summaries and Florida Museum species accounts.
Cockatoo Waspfish has an accessible Museums Victoria Fishes of Australia account.
`Data/CatalogReview/SourceInspectionEvidence.json` records exact URLs, named
sections, field evidence, inspection date and outstanding decisions.
`Reports/CatalogueSourceReviewPass.json` binds those observations to complete
current publication content, stable source identities and SHA-256 fingerprints.
Its blank human-decision fields are a handoff, not synthetic approval.

| Record / stable ID | Supported correction | Exact decision still needed |
| --- | --- | --- |
| Atlantic Blue Tang `00000000-0000-0000-0000-000000000003` | FishBase depth maximum 50 m; remove unsupported typical and juvenile size intervals | Resolve FishBase 39 cm / 2–50 m versus Museum 37 cm / 2–40 m; confirm locality/frequency list |
| Stoplight Parrotfish `00000000-0000-0000-0000-000000000005` | FishBase maximum 64 cm TL, minimum depth 3 m; Museum rounded head; remove unsupported size intervals and separate juvenile description from initial phase | Resolve FishBase 64 cm versus Museum 55 cm; confirm life stages, taxonomy authority and localities |
| Queen Angelfish `fc213eff-6ba6-53ab-b288-f6e654299e68` | FishBase 1–70 m, forehead spot, pectoral-base blue spot, reef and solitary coding; maximum not encoded as typical size | Confirm coding, locality/frequency list and French Angelfish comparison |
| Cockatoo Waspfish `5f4d48f4-6556-50f3-95af-a4d28635f4bb` | Fishes of Australia maximum 15 cm TL and recorded depth 0–80 m; usual habitat to 20 m remains distinct | Accept authoritative replacement for unavailable book p. 381 / PDF p. 382; reconcile transcription 16 cm and 17 spines with replacement 15 cm and 17–18 spines; check full taxonomy/range |

For **each** record a real human must inspect the linked accounts and complete
content, resolve its packet's questions, and supply an actual identity, UTC review
date and notes covering the exact fingerprint. Only then change its overlay to
`verified` and clear resolved questions. If content changes, recompute the
fingerprint after applying corrections; a decision for old content is stale.
Do not substitute the automated inspection date for a human review date. The
current draft corrections neither imply sourceChecked nor publication permission.

Five other Caribbean starter records remain deferred with their original source
references in the report. Green Sea Turtle specifically needs an authoritative
turtle account to replace its inappropriate FishBase fish reference. Seven
Pacific OCR-category packets still need original pages or documented replacement
evidence. No locality evidence or missing original page was invented.

## Reproduction

The Caribbean baseline preserves the full pre-overlay input from the inspected
main tree, including original sources. `CaribbeanReviewDecisions.json` adds
supported corrections and supplementary museum provenance. The existing
`apply_decisions` validator applies the entire overlay and validates the pack
before the transactional catalogue/manifest replacement. Regeneration rejects
stale or blocked decisions. Pacific retains its workbook/import/overlay pipeline.
Edit those inputs/decisions, not generated catalogue records.

```sh
python3 Tools/CatalogReview/regenerate_caribbean.py
python3 Tools/CatalogImport/import_tropical_pacific.py
python3 Tools/CatalogReview/prepare_source_review_pass.py
python3 Tools/CatalogReview/prepare_review_batch.py
python3 Tools/CatalogReview/verify_source_review_reproducibility.py
```

Use the documented Python dependencies (including openpyxl). Two complete
regenerations produced byte-identical catalogues, manifests and reports;
`Reports/SourceReviewReproducibility.json` stores hashes for nine artifacts.
Original species IDs, original source metadata, artwork and unrelated records
are preserved. Supplementary page access dates are explicitly new provenance.

## Validation for this pass

Bundled tests now derive review accounting and publication availability from
actual statuses in both packs. A dedicated all-draft fixture and mixed-status
fixtures still prove that drafts cannot enter publication search. Synthetic
reviewers occur only in test fixtures; they approve no real records.

Python: 72 tests passed (review 19, import 6, workbook 9, semantic 33, CI 5).
SwiftPM Debug: 106 tests, one opt-in frozen evaluation skipped, one quality-gate
failure. Full Pacific fixture passes; all positive bounds and no-match assertions
are unchanged. Caribbean production hybrid top-1/3/10 remains 43/44/45 with all
14 no-match cases correct and 56/56 candidate recall. Structured search changes
from 39/42/45 to 40/41/45: the top-3 floor remains 42 and fails visibly. Case
`realistic-029` moves from rank 3 to 4 after supported catalogue corrections;
`realistic-014` improves from 2 to 1. Search/ranking code and fixtures are untouched.

SwiftPM Release also built and executed 106 tests with the same one quality-gate
failure and one opt-in skip. All 13 catalogue-diagnostic tests, 15 Pacific tests,
and 16 saved-record persistence/compatibility tests passed in each configuration.
Both actual publication gates reported approved=0 / available=false. These are
Linux SwiftPM Release checks, not an Xcode app build. No genuinely approved record
exists to demonstrate successful Release identification or region switching.
Portable filtering, labels and saved-record compatibility are useful test evidence,
not proof of a publication-ready catalogue. Xcode/device behavior remains unverified
in this Linux environment.

The following sections are historical observations, retained as an audit trail.
The current packet replaces the earlier inaccessible-source handoff; historical
counts and test failures must not be read as results of the current pass.

## Historical source-review pass (2026-09-26; superseded below by current packets)

The current manifests and decoded catalogues were counted again for this pass; the
figures below are observations of the current files, not the previously reported
figures carried forward. Caribbean still contains 8 structurally included records
and Tropical Pacific still contains 384. Both manifests report 0 human-reviewed
and 0 publication-eligible records, and every decoded record remains `draft`.
Consequently, publication access exposes 0 regions and 0 records in Release.

`Reports/CatalogueSourceReviewPass.json` is the complete handoff for a deliberately
small selection from the existing packets:

* `fc213eff-6ba6-53ab-b288-f6e654299e68` — Queen Angelfish
* `00000000-0000-0000-0000-000000000003` — Atlantic Blue Tang
* `00000000-0000-0000-0000-000000000005` — Stoplight Parrotfish

These were preferred because each has a direct species page and Queen Angelfish is
the only existing packet with a second, museum-hosted species profile. Retrieval of
all four referenced URLs was attempted on 2026-09-26. Each request was refused with
HTTP 403 in the validation environment, and the repository contains no captured
original page. An HTTP status is not biological evidence. No page content was
inspected, no value was inferred from the existing catalogue prose, and no category
or other field was reconstructed. The handoff therefore preserves each stable ID,
source identity, exact references, original packet text, full current record,
content fingerprint, field-by-field unresolved state, and empty correction set.

No explicit human decision covers these current fingerprints. No reviewer identity,
date, or approval was created, and no overlay decision was applied. To unblock each
record, a reviewer must obtain every listed page (or record an accessible,
authoritative replacement source with a stable locator), compare identity, category,
traits, size, depth, habitat, and range against the recorded snapshot, document each
field correction and unresolved question, and provide a named, dated decision with
notes. Until then all three records remain draft and Release catalogue availability
remains blocked.

The Tropical Pacific importer and first-packet generator were run twice. The six
generated catalogue/report artifacts had identical SHA-256 hashes after both runs.
Portable Swift and Python checks can exercise publication filtering, mixed-pack
accounting, saved snapshots, and region recovery synthetically, but there is no real
approved record with which to run the requested Release search. Xcode, Simulator,
and physical-device checks remain unavailable in this Linux environment.

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
