# Tropical Pacific starter catalogue

The 40-record pack is generated from `DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx`; do not hand-edit its JSON. Run:

```sh
python3 -m pip install -r Tools/CatalogImport/requirements.txt
python3 Tools/CatalogImport/import_tropical_pacific.py
```

Selection is deterministic and limited to records with workbook-supported regional presence, a complete high-confidence identity (score 100), high-confidence account transcription, a high-confidence identification trait, and species-account provenance. Workbook UUIDs are retained. The JSON keeps the record at `draft`: this import is not an external taxonomy verification.

Unsupported fields are null/empty. In particular, typical size, aliases, cautions, structured body/head/fin details, images, and external taxonomy identifiers are not inferred. The workbook's book-scan photographs are `reference_only_not_licensed_for_app`; the importer deliberately reads no Media rows and creates no image records.

`Reports/TropicalPacificExclusions.csv` lists every workbook record not selected and its reason. `Reports/TropicalPacificImportReport.json` records policy, counts, selected UUIDs, and the media/unsupported-field rules.

## Evaluation scope

`TropicalPacificSearchEvaluationTests` exercises positive, ambiguous, and genuine no-match text and records candidate recall at 10, 25, and 50. These checks are catalogue/search regression evidence, not a claim of production identification quality. The legacy Caribbean benchmark contains only eight species and likewise must not be presented as production-quality validation.
