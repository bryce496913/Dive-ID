# Dive-ID global marine species research: target 5,000

This folder contains **4,000 distinct, source-linked marine-life research candidates**, staged separately from the existing **1,000-record Tropical Pacific development catalogue** and the separately maintained eight-record Caribbean catalogue.

## Status

**RESEARCH / DRAFT ONLY.** No new record has received human approval. These are not 4,000 complete or verified identification profiles and must not be exposed in Release. Importing them into the Tropical Pacific pack without separate distribution verification would misrepresent their geographic occurrence. Do **not** merge them directly into `DiveID/Resources/IdentificationPacks/TropicalPacific/Creatures.json`.

### Contents

- `ResearchProfiles.01.json` ... `ResearchProfiles.10.json`: 400 records each, shaped to the current `LocalSpeciesProfile` JSON fields. UUIDs are deterministic, not randomly generated.
- `SourceIndex.01.json` ... `SourceIndex.04.json`: 1,000 source-evidence index rows each, including taxonomic provenance, missing fields, source distribution groups and image-reference counts.
- `Expansion5000.audit.json`: high-level counts, sources, known gaps, and validation constraints.

### Source trail

1. **Reef Life Survey, Reef Species of the World** — 3,938 species from [public rls-data source](https://github.com/reef-life-survey/rls-data/blob/master/output/species.json), pinned to commit `47fe46699c996e8a3c0499315c8448343ddb4e03`. Per-species RLS URLs retained. No photos copied, and full source species descriptions are not reproduced.
2. **Genner Lab meta-fish-lib** — 62 additional accepted-name table entries with source FishBase IDs, from [species-table.csv](https://github.com/genner-lab/meta-fish-lib/blob/main/assets/species-table.csv). Each is also present in the MOBS marine taxonomy snapshot. Their regions and appearance remain unknown.
3. **MOBS 1.0** — 3,384 candidates cross-matched to historical WoRMS-linked AphiaIDs in [MOBS's source table](https://github.com/crmcclain/MOBS_OPEN/blob/main/data_all_112224.csv). Required citation: McClain et al. (2025), *Global Ecology and Biogeography*, DOI [10.1111/geb.70062](https://doi.org/10.1111/geb.70062). This is a **2024 snapshot**, not a live 2026 WoRMS verification.

RLS / third-party data rights must be reviewed before commercial reuse; the processor repository's MIT code license does not automatically license all descriptions and photographs.

## Current structural coverage

- **4,000** unique records, all `review.status = draft`.
- **3,384** historical AphiaID matches.
- **1,731** have source RLS descriptions (only derived vocabulary clues are retained).
- **1,207** have parseable source depth limits, and **2,891** have reported maximum lengths. Do not assume maximum lengths represent total length.
- **1,690** have broad RLS distribution labels; the rest have no substantiated region assignment.
- **2,738** have RLS photography references, but no images are bundled or licensed for use.
- **409** have no compatible category in the current iOS controlled vocabulary (often echinoderms or other marine-life groups).

## Codex integration contract

1. **Keep a distinct research-candidate layer** reading the ten JSON parts, not a silently expanded Tropical Pacific production pack.
2. Retain all baseline UUIDs. Source IDs are deterministic UUIDv5 based on namespace `8d2baf7b-aad1-497e-8e7d-2dff4c935efc` and either `rls:<scientificName>` or `metafish:<scientificName>`. Record migrations when accepted scientific names change.
3. Validate all 4,000 draft objects against the current canonical model and controlled vocabulary. Do not infer negative evidence from missing fields. Preserve null AphiaID and measurement-type gaps.
4. Match names against **live WoRMS** (including synonyms and accepted-name redirects), correct incorrect class/family assignments, and verify morphology independently at the species level. Flag lookalikes, life stages, regional occurrence and missing common names.
5. Prioritize the 1,731 with source descriptions; review field facts and rights; create category support for unmapped taxa if relevant to divers.
6. Build **region-specific subsets** from occurrence data (OBIS / RLS site surveys and another locality source as necessary), with named/dated human verification before publication. Do not interpret a global marine listing as tropical Pacific presence.
7. Preserve the current review fingerprint/approval logic and frozen BM25 / no-match / region-contraindication regression gates. Test latency and memory on an actual iPhone before broadening the searchable development set.
8. Until reviewed, keep all 4,000 unapproved out of Release. Existing 2 approved Caribbean records must remain unchanged.

**Definition of done:** exactly 4,000 researched candidates can be parsed and deduplicated independently, with audit and provenance; `main` publication and existing regional packs remain untouched until a separate, tested import PR.
