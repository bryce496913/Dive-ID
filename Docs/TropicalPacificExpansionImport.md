# Tropical Pacific draft expansion import

The default importer combines the 384 records admitted by the existing workbook
rules with the explicit 616-record development supplement. It does not relax those
rules: workbook outcomes still report 384 included and 1,266 pending review.
The manifest separately describes the resulting 1,000-record development pack,
version 3. Caribbean remains eight records; total development coverage is 1,008.

Inputs are preserved verbatim from branch
`data/tropical-pacific-1000-draft-expansion-20261014`, commit
`e7cedab82e9deaae8bcc06f8cf4d09e6504f74a5`:

- `Data/TropicalPacific/TropicalPacificExpansion616.draft.json`
- `Data/TropicalPacific/TropicalPacificExpansion616.audit.json`

These are non-authoritative OCR candidates, including 508 medium-confidence
transcriptions and summaries generated from extracted terms. Import is not source
review. The audit and original record provenance remain intact; input SHA-256
identities are recorded in `Reports/TropicalPacificImportReport.json`.

The importer validates the combined schema, canonical UUID uniqueness, common and
scientific identities and aliases, draft status, audit counts and exact selected
ID set before replacing catalogue outputs. It rejects collisions rather than
silently dropping records. Sorting uses common name then stable UUID. Existing
review overlays run after the merge; stale/invalid decisions abort generation.
No UUID is regenerated. Both catalogue files are staged and replaced with rollback
on replacement failure, including first generation into an empty output directory.

Run from the repository root with the declared Python requirements installed:

```sh
python3 Tools/CatalogImport/import_tropical_pacific.py
python3 Tools/CatalogReview/prepare_source_review_pass.py
python3 Tools/CatalogReview/prepare_review_batch.py
python3 Tools/CatalogReview/publication_expectations.py
python3 Tools/CatalogReview/verify_source_review_reproducibility.py
python3 -m unittest discover -s Tools/CatalogImport -p 'test_*.py'
python3 -m unittest discover -s Tools/CatalogReview -p 'test_*.py'
swift test --jobs 4
swift test -c release --jobs 4
python3 Tools/Evaluation/run_v05.py --output /tmp/expansion-evaluation.json --log /tmp/expansion-evaluation.log
```

Publication remains exactly the two approved Caribbean IDs:
`00000000-0000-0000-0000-000000000003` and
`fc213eff-6ba6-53ab-b288-f6e654299e68`.
Pacific has zero publication-eligible records and remains unavailable under
publication access. The actual bundled-repository tests compare exact eligible
sets against the oracle derived from validated human decisions, and verify draft
exclusion and unavailable-region behavior. Optimized Linux SwiftPM execution is
not installed iOS Release validation; Xcode/device checks require Apple tooling.

Do not relax frozen search gates to accommodate the expansion. A larger draft
pack can introduce confusing alternatives; failures require a separate,
evidence-supported search-quality pass.
