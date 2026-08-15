# Tropical Pacific Workbook Profile

## Source

DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx

## Sheets

| Sheet | Rows | Columns |
|---|---:|---:|
| README | 37 | 2 |
| Creatures | 1650 | 34 |
| Traits | 1600 | 10 |
| Sources | 1651 | 11 |
| Comparisons | 75 | 11 |
| Media | 1620 | 12 |
| Benchmarks | 0 | 8 |
| Validation | 342 | 5 |
| Data Dictionary | 98 | 7 |
| Index Coverage | 3602 | 7 |

### README

Columns: `Field`, `Value`

### Creatures

Columns: `creature_id`, `common_name`, `scientific_name_printed`, `aphia_id`, `taxonomy_status`, `region`, `category`, `family_printed_raw`, `typical_size_cm`, `max_size_cm`, `depth_min_m`, `depth_max_m`, `broad_range`, `range_detail_raw`, `occurrence_status`, `occurrence_basis`, `source_id`, `source_book_page`, `source_pdf_page`, `source_tile`, `status`, `transcription_confidence`, `human_review_required`, `scientific_match_score`, `common_match_score`, `secondary_ocr_match_score`, `identity_basis`, `identity_confidence`, `identity_confidence_score`, `text_transcription_confidence`, `text_transcription_score`, `source_title_common_ocr`, `source_title_scientific_ocr`, `extraction_method`

### Traits

Columns: `trait_id`, `creature_id`, `life_stage`, `trait_type`, `value`, `source_id`, `source_book_page`, `source_tile`, `transcription_confidence`, `status`

### Sources

Columns: `source_id`, `creature_id`, `species_specific_url`, `source_locator`, `citation`, `licence`, `licence_url`, `accessed_date`, `supported_fields`, `source_type`, `notes`

### Comparisons

Columns: `comparison_id`, `creature_id`, `confusable_creature_id`, `visible_difference`, `source_id`, `source_book_page`, `resolution_status`, `candidate_common_name`, `candidate_match_score`, `identity_confidence`, `text_transcription_confidence`

### Media

Columns: `media_id`, `creature_id`, `filename_or_url`, `source_locator`, `creator`, `licence`, `licence_url`, `alt_text`, `life_stage`, `source_id`, `credit_source_id`, `media_use_status`

### Benchmarks

Columns: `benchmark_id`, `real_description`, `expected_creature_id`, `maximum_acceptable_rank`, `difficulty`, `split`, `source_id`, `status`

### Validation

Columns: `severity`, `entity_type`, `entity_id`, `issue`, `detail`

### Data Dictionary

Columns: `sheet`, `column`, `type`, `definition`, `units_or_vocabulary`, `null_meaning`, `key_relationship`

### Index Coverage

Columns: `index_type`, `name`, `book_page`, `source_file`, `raw_index_text`, `index_group_or_parse_status`, `mapping_note`

## Data Dictionary

The Data Dictionary defines field types and meanings, controlled vocabularies or units, null meanings, and key relationships.

**Primary keys:** `Creatures.creature_id`, `Traits.trait_id`, `Sources.source_id`, `Comparisons.comparison_id`, `Media.media_id`, `Benchmarks.benchmark_id`.

**Units/vocabularies:** `Creatures.creature_id`: UUID5; `Creatures.common_name`: source wording; `Creatures.scientific_name_printed`: source form; `Creatures.aphia_id`: AphiaID; `Creatures.taxonomy_status`: unverified_from_source | unresolved_sp_from_source; `Creatures.region`: Tropical Pacific; `Creatures.category`: source wording; `Creatures.family_printed_raw`: source wording; `Creatures.typical_size_cm`: cm; `Creatures.max_size_cm`: cm; `Creatures.depth_min_m`: m; `Creatures.depth_max_m`: m; `Creatures.broad_range`: source wording; `Creatures.range_detail_raw`: source wording; `Creatures.occurrence_status`: presence_supported; `Creatures.occurrence_basis`: text; `Creatures.source_id`: SRC-*; `Creatures.source_book_page`: page; `Creatures.source_pdf_page`: page; `Creatures.source_tile`: tl|tr|ml|mr|bl|br; `Creatures.status`: draft|verified|rejected; `Creatures.transcription_confidence`: high|medium|low; `Creatures.human_review_required`: TRUE/FALSE; `Creatures.scientific_match_score`: 0-100; `Creatures.common_match_score`: 0-100; `Creatures.secondary_ocr_match_score`: 0-100; `Creatures.identity_basis`: binomial_index|provisional_sp_profile; `Traits.trait_id`: TRT-*; `Traits.creature_id`: UUID5; `Traits.life_stage`: adult/general|juvenile|male|female|variation|phase; `Traits.trait_type`: identification_description; `Traits.value`: source wording/OCR; `Traits.source_id`: SRC-*; `Traits.source_book_page`: page; `Traits.source_tile`: tl|tr|ml|mr|bl|br; `Traits.transcription_confidence`: high|medium|low; `Traits.status`: draft|verified|rejected; `Sources.source_id`: SRC-*; `Sources.creature_id`: UUID5; `Sources.species_specific_url`: URL; `Sources.source_locator`: book/PDF page; `Sources.citation`: text; `Sources.licence`: text; `Sources.licence_url`: URL; `Sources.accessed_date`: YYYY-MM-DD; `Sources.supported_fields`: field list; `Sources.source_type`: book_scan; `Sources.notes`: text; `Comparisons.comparison_id`: CMP-*; `Comparisons.creature_id`: UUID5; `Comparisons.confusable_creature_id`: UUID5; `Comparisons.visible_difference`: source wording/OCR; `Comparisons.source_id`: SRC-*; `Comparisons.source_book_page`: page; `Comparisons.resolution_status`: resolved_high_confidence|resolved_medium_confidence|unresolved_needs_review; `Comparisons.candidate_common_name`: source/candidate wording; `Comparisons.candidate_match_score`: 0-100; `Media.media_id`: MED-*; `Media.creature_id`: UUID5; `Media.filename_or_url`: path/URL; `Media.source_locator`: page + tile; `Media.creator`: source wording; `Media.licence`: text; `Media.licence_url`: URL; `Media.alt_text`: text; `Media.life_stage`: adult/general|juvenile|male|female|variation; `Media.source_id`: SRC-*; `Media.credit_source_id`: SRC-PHOTO-CREDITS; `Media.media_use_status`: reference_only_not_licensed_for_app; `Benchmarks.benchmark_id`: BEN-*; `Benchmarks.real_description`: text; `Benchmarks.expected_creature_id`: UUID5; `Benchmarks.maximum_acceptable_rank`: positive integer; `Benchmarks.difficulty`: easy|medium|hard; `Benchmarks.split`: train|validation|test; `Benchmarks.source_id`: SRC-*; `Benchmarks.status`: draft|verified|rejected; `Validation.severity`: info|warning|error; `Validation.entity_type`: text; `Validation.entity_id`: ID/GLOBAL; `Validation.issue`: text; `Validation.detail`: text; `Index Coverage.index_type`: common_name|scientific_name; `Index Coverage.name`: source/OCR wording; `Index Coverage.book_page`: page; `Index Coverage.source_file`: filename; `Index Coverage.raw_index_text`: OCR text; `Index Coverage.index_group_or_parse_status`: source group|strict_binomial|needs_review; `Index Coverage.mapping_note`: text; `Creatures.identity_confidence`: high|medium|low; `Creatures.identity_confidence_score`: 0-100; `Creatures.text_transcription_confidence`: high|medium|low; `Creatures.text_transcription_score`: 0-100; `Creatures.source_title_common_ocr`: source OCR; `Creatures.source_title_scientific_ocr`: source OCR; `Creatures.extraction_method`: pdf_account_tile_reconciled | ...plus_manual_visual_check | manual_visual_pdf_account_verification | index_only_or_unresolved; `Comparisons.identity_confidence`: high|medium|low; `Comparisons.text_transcription_confidence`: high|medium|low.

**Nullable fields:** Null meanings are documented for 98 fields; a null may mean missing/unresolved source data, intentional deferral, or an inapplicable optional relationship. Fields marked “Never null” are treated as required keys.

## Expected Dataset Relationships

- `Creatures.source_id` → `Sources.source_id`
- `Traits.creature_id` → `Creatures.creature_id`
- `Traits.source_id` → `Sources.source_id`
- `Sources.creature_id` → `Creatures.creature_id`
- `Comparisons.creature_id` → `Creatures.creature_id`
- `Comparisons.confusable_creature_id` → `Creatures.creature_id`
- `Comparisons.source_id` → `Sources.source_id`
- `Media.creature_id` → `Creatures.creature_id`
- `Media.source_id` → `Sources.source_id`
- `Media.credit_source_id` → `Sources.source_id`
- `Benchmarks.expected_creature_id` → `Creatures.creature_id`
- `Benchmarks.source_id` → `Sources.source_id`

## Structural Validation

- Missing required/documented sheets: 0
- Missing expected columns: 0
- README duplicate headers: 0
- README missing header cells: 0
- README completely empty columns: 0
- Creatures duplicate headers: 0
- Creatures missing header cells: 0
- Creatures completely empty columns: 6 (examples: `aphia_id`, `typical_size_cm`, `text_transcription_score`, `source_title_common_ocr`, `source_title_scientific_ocr`)
- Traits duplicate headers: 0
- Traits missing header cells: 0
- Traits completely empty columns: 0
- Sources duplicate headers: 0
- Sources missing header cells: 0
- Sources completely empty columns: 2 (examples: `species_specific_url`, `licence_url`)
- Comparisons duplicate headers: 0
- Comparisons missing header cells: 0
- Comparisons completely empty columns: 0
- Media duplicate headers: 0
- Media missing header cells: 0
- Media completely empty columns: 2 (examples: `filename_or_url`, `licence_url`)
- Benchmarks duplicate headers: 0
- Benchmarks missing header cells: 0
- Benchmarks completely empty columns: 8 (examples: `benchmark_id`, `real_description`, `expected_creature_id`, `maximum_acceptable_rank`, `difficulty`)
- Validation duplicate headers: 0
- Validation missing header cells: 0
- Validation completely empty columns: 0
- Data Dictionary duplicate headers: 0
- Data Dictionary missing header cells: 0
- Data Dictionary completely empty columns: 0
- Index Coverage duplicate headers: 0
- Index Coverage missing header cells: 0
- Index Coverage completely empty columns: 0
- Creatures duplicate `creature_id` values: 0
- Creatures blank `creature_id` values: 0
- Creatures malformed `creature_id` values: 0
- Traits duplicate `trait_id` values: 0
- Traits blank `trait_id` values: 0
- Traits malformed `trait_id` values: 0
- Sources duplicate `source_id` values: 0
- Sources blank `source_id` values: 0
- Sources malformed `source_id` values: 0
- Comparisons duplicate `comparison_id` values: 0
- Comparisons blank `comparison_id` values: 0
- Comparisons malformed `comparison_id` values: 0
- Media duplicate `media_id` values: 0
- Media blank `media_id` values: 0
- Media malformed `media_id` values: 0
- Benchmarks duplicate `benchmark_id` values: 0
- Benchmarks blank `benchmark_id` values: 0
- Benchmarks malformed `benchmark_id` values: 0
- Creatures.`source_id` orphan references: 0
- Traits.`creature_id` orphan references: 0
- Traits.`source_id` orphan references: 0
- Sources.`creature_id` orphan references: 0
- Comparisons.`creature_id` orphan references: 0
- Comparisons.`confusable_creature_id` orphan references: 0
- Comparisons.`source_id` orphan references: 0
- Media.`creature_id` orphan references: 0
- Media.`source_id` orphan references: 0
- Media.`credit_source_id` orphan references: 0
- Benchmarks.`expected_creature_id` orphan references: 0
- Benchmarks.`source_id` orphan references: 0
- Unexpected/unparseable Data Dictionary relationships: 0

## Small Data Quality Summary

- Creature count: 1650
- Missing common names: 50
- Missing scientific names: 1
- Missing categories: 55
- Missing typical size: 1650
- Missing maximum size: 55
- Missing depth minimum: 692
- Missing depth maximum: 174
- Missing range information: 125
- Records requiring human review: 1650
- Draft records: 1650
- Low transcription-confidence records: 125
- Medium transcription-confidence records: 887
- Comparison count: 75
- Media count: 1620
- Validation record count: 342
- Validation-warning count: 225

## Catalogue Architecture Context

The current app represents catalogue records with `LocalSpeciesProfile`, `SpeciesTaxonomy`, `SpeciesMeasurements`, `RecordReview`, and `SpeciesDataSourceReference`. `BundleMarineSpeciesCatalogRepository` loads the bundled Caribbean identification pack. This profile does not transform workbook rows into those models, alter the Caribbean pack, or register a Tropical Pacific pack.
