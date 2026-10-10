# Caribbean source review batch v1

Baseline: main `b8e626f599bf7425d3ed115b2d690b76dd772c21` (PR #90 merged). Automated source inspection: 2026-10-10. This is preparation for human review, not publication approval.

| Record | Stable ID | Decision |
| --- | --- | --- |
| Atlantic Blue Tang | 00000000-0000-0000-0000-000000000003 | draft; human decision outstanding |
| Queen Angelfish | fc213eff-6ba6-53ab-b288-f6e654299e68 | draft; human decision outstanding |

The two records tagged `caribbean-two-records-v1` in `CatalogueSourceReviewPass.json` contain the complete corrected publication content, exact SHA-256 fingerprints, source identities, section citations, field audits and blank human decision forms. `SourceInspectionEvidence.json` is the editable evidence input. Original source entries and stable species IDs are preserved.

Inspected FishBase species summaries and Florida Museum Blue Tang and Queen Angelfish accounts, plus the Museum French Angelfish account for the adult comparison. Precise URLs and sections are in the packets. Removed unsupported enumerated localities (Blue Tang retains explicitly documented Bahamas; Queen has no locality enumeration). Broad Caribbean abundance supports the existing common label, now qualified as regional rather than site-specific. Blue Tang mouth wording now follows the source's position description. Queen's comparison is explicitly adult-only and uses supported positive traits instead of an inferred absence of a crown. Added comparison provenance without replacing original sources.

Human decisions required:

1. Blue Tang: accept or revise FishBase's 39 cm TL and 2–50 m recorded limits against Museum's 37 cm and 2–40 m; confirm the restricted locality and broad occurrence interpretation.
2. Queen: confirm adult diagnostic coding, 45 cm TL / 1–70 m limits and the cited adult French comparison; accept incomplete juvenile coverage and non-enumerated locality coverage. Retain `ciliaris`: Museum's classification list has a conflicting spelling, while its heading/Taxonomy and FishBase agree.
3. For each record, inspect the entire fingerprint-bound content, resolve all questions, then supply an actual reviewer identity, actual review date, decision and notes. Apply that decision to the validated Caribbean overlay with the same fingerprint. Any content change requires a new fingerprint and review. Source reading and successful tests alone do not authorize `verified`.

No human approval was supplied or found. Applied draft corrections only. Caribbean: 8 included, 8 draft, 0 approved. Pacific: 384 included, 384 draft, 0 approved. Actual publication access has no available packs. Release positive search remains blocked. Synthetic verified test records only validate filtering mechanics; they are not real approvals.

Reproduce from repository root with the project's Python environment:

```sh
python Tools/CatalogReview/regenerate_caribbean.py
python Tools/CatalogReview/prepare_source_review_pass.py
python Tools/CatalogReview/prepare_review_batch.py
python Tools/CatalogReview/verify_source_review_reproducibility.py
python -m unittest discover -s Tools/CatalogReview -p 'test_*.py'
swift test --jobs 4
```

Two successive full regenerations were byte-identical; hashes are in `SourceReviewReproducibility.json`. Both manifests remain unchanged because counts/statuses did not change. Publication validation and search fixture expectations remain unchanged.

Validation on the resulting candidate tree (Linux Swift 6.2.3): 19 review tests and 6 import tests passed. Swift ran 124 tests, with 2 skipped and 2 assertion failures in the existing `v05-17-paraphrase` rank case (production BM25 and structured diagnostic engine). These are the same baseline failures; evaluation inputs, rank bounds and thresholds were not changed. Pacific quality gates, Caribbean production search, publication filtering/count/status tests, all 8 saved-record compatibility tests and all 8 persistence tests passed. Persistence coverage includes reopening the same file with a new repository instance and historical record migration. No new real approval was available to exercise published positive search. Xcode, simulator and device validation were not executed on this Linux host.
