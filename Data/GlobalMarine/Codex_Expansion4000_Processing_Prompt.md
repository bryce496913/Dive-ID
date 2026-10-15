# Codex pass: Process the 4,000 globally sourced Dive-ID candidates without bypassing review

## Repository and baseline
Repository: https://github.com/bryce496913/Dive-ID
Input branch: `data/global-marine-4000-candidate-queue-20261015`
Baseline `main` commit at source snapshot: `d6bb2667f027cf6cee63ebdae3c5cd83df4d58b1` (rebase/check newest main before implementation).

Read before implementation:
- `Data/GlobalMarine/Expansion4000_CandidateQueue.csv` — exactly 4,000 source-derived, **unverified** names.
- `Data/GlobalMarine/Expansion4000_ReserveQueue.csv` — 529 fallbacks, not already part of the target.
- `Data/GlobalMarine/Expansion4000_Audit.json` — source snapshots, bucket quotas and caveats.
- `Docs/TropicalPacificExpansionImport.md`
- `Tools/CatalogImport/import_tropical_pacific.py`
- `Tools/CatalogReview/catalog_review.py`, `catalogue_validation.py`
- `DiveID/Core/Models/LocalSpeciesProfile.swift`
- `DiveID/Core/Catalog/Schema/CatalogueVocabulary.swift`
- `DiveID/Core/Services/BundleMarineSpeciesCatalogRepository.swift`
- `Reports/TropicalPacificExpansionValidation.md`

## Objective
Build a deterministic, resumable research and staging pipeline for 4,000 candidate taxa while protecting the existing 1,000 Tropical Pacific + 8 Caribbean development records. Do **not** claim 5,000 published, independently verified or searchable creatures merely because 4,000 rows are in a source list.

The new input is **global**, not proof of presence in the Tropical Pacific. Never merge globally sourced candidates automatically into `TropicalPacific/Creatures.json` or `Caribbean/Creatures.json`. Preserve all existing source IDs, UUIDs, approved human decisions, release filtering and frozen benchmark expectations.

## Work passes — separate small PRs where practical

### Pass 1 — candidate intake, identity crosswalk and validation
1. Add a separate `Tools/GlobalMarineImport/` pipeline and source-backed `Data/GlobalMarine/` stages, not a new ad-hoc production JSON editor.
2. Validate that the primary queue has exactly 4,000 rows with unique candidate IDs and case-insensitive scientific-name inputs. Check `Expansion4000_Audit.json` and source snapshots. Keep the 529 reserves separate.
3. Compare against **all** current application packs, the 616 supplement, and all 1,650 workbook identities including pending-review rows. Reuse `existingWorkbookCreatureID` when it is verified to match; fail on conflicts rather than generating a duplicate. Canonicalize whitespace/case but do not silently guess corrected Latin spelling.
4. Treat all input names/families/FishBase SpecCodes and reported maxima as **historic candidate metadata**. `sourceReportedMaxSizeCmUnverified` is not automatically `maximumSizeCentimeters`; its unit may not be an app-supported type.
5. Produce a machine-readable audit with per-bucket counts, source lineage, known existing-workbook links, ID collisions, uncertain categories, stale source names, unresolved aliases and rejected rows.
6. Do not mark any row `sourceChecked` or `verified` solely because a third-party list contained it.

### Pass 2 — taxonomic verification and durable caching
1. Use WoRMS REST (https://www.marinespecies.org/aphia.php?p=webservice) to resolve **species-rank**, extant, marine taxa. Match input binomials by exact query first; fuzzy matches are candidates requiring explicit review, not auto-accepted.
2. Record original source name, accepted scientific name, accepted AphiaID (`valid_AphiaID`), supplied/source AphiaID when relevant, taxonomic status, authority, genus, family, class, rank, marine flag, resolver URL, retrieval timestamp, response fingerprint, and diagnostics. Use null for unknown values. Never fabricate AphiaIDs.
3. Resolve aliases and taxonomic synonyms to a single accepted taxon. Do not merge distinct species merely because they share common names. Preserve every original candidate ID and source name in a crosswalk.
4. Handle unavailable API, timeouts, rate limits, 429/5xx, response-shape changes and empty responses separately; failed requests stay retryable, not `not a species`. Limit concurrency (e.g. 2–4), use bounded exponential backoff and incremental checked-in source snapshots or a documented deterministic cache workflow.
5. Process in **16 checkpoints of 250 candidates**. Make `--batch`, `--resume`, `--offline-cache-only`, `--dry-run`, `--report` flags deterministic and documented. Never require every online request to succeed before saving already completed work.
6. If two inputs resolve to the same accepted AphiaID, report the collision; use the ranked reserve queue and repeat validation to replenish the distinct canonical candidate set. If 4,000 accepted unique marine species are not genuinely obtainable, report the smaller verified count rather than padding with unverifiable names.

### Pass 3 — field-specific enrichment and diver relevance
1. Prioritize visible/recognizable reef fish, morays, snake eels, seahorses/pipefish, reef/coastal sharks and rays, sea turtles, octopus/squid, lobsters/crabs/shrimp, nudibranchs, starfish/urchins and sea cucumbers.
2. Use FishBase, species-specific Fishes of Australia / Museums Victoria and other authoritative museum/NOAA sources for independent identity/traits; use WoRMS for taxonomy; consider OBIS and species-specific regional references for occurrence. No unsupported per-island, depth, body color, behavior, size, habitat, life-stage or abundance assertions. Do not copy substantial copyrighted source narrative.
3. Attribute **each enriched field** to an exact species URL, supported field/section, access date and evidence status. Store conflicting sources and reviewer questions. Keep nulls where support is missing; do not derive common names from Latin names or label inferred regions as observed.
4. `proposedAppCategory` and source family are provisional. There are 59 `needs_taxon_group` candidates, including echinoderms; add genuine categories (e.g. `echinoderm`, `cnidarian`, `sponge`) only in a scoped schema/vocabulary PR with parser/ranker/validator and backward-compatibility tests. Never misclassify these taxa as mollusks or fish.
5. Preserve distinction between printed/source names and accepted names, and between maximum-recorded size and observed-identification ranges, including length vs disc width vs carapace length; add unsupported measurement types only with a separate schema change.
6. Treat photos as unavailable by default. Do not import copyrighted source-book photos or scrape images without license/creator/source/attribution verification.

### Pass 4 — regional staging, publication gates, and quality validation
1. Keep candidates in a global **staging/review queue**, not an app-visible region. Only export records to a region pack when species-specific evidence supports occurrence there. A global reef checklist does **not** confer Tropical Pacific, Caribbean, Hawaiian, or local occurrence.
2. Preserve actual `RecordReview` decisions and source fingerprints. New profiles remain `draft` until a named reviewer checks exact content, sources and date. Never generate fake reviewer identities, dates, approvals, common names or media licenses.
3. Release must continue to expose only the existing independently approved records (currently the two verified Caribbean IDs, subject to later legitimate review decisions). Keep manifest accounting derived and exact. Never change search acceptance thresholds to make a larger pack look healthy.
4. Baseline warning: PR #103 already has three search-test areas failing, including Fire Dartfish slipping to rank 6 and `v05-14-paraphrase` absent. Run the frozen evaluation before and after, document pre-existing failures separately, and **block additional regressions**. Do not hide or weaken pre-existing failures.
5. Validate production BM25 + biological reranking, regional incompatibilities, negative/ambiguous descriptions, performance and memory budgets with realistic pack sizes. The existing independent diver pilot has zero real submitted cases; do not claim real-world accuracy from synthetic fixtures.
6. Run Python importer/review/tooling tests, SwiftPM Debug + optimized Release tests, deterministic regeneration twice, `git diff --check`, and if macOS/Xcode is available iPhone simulator/physical-device validation. Label unavailable tests explicitly; no fabricated device results.
7. Separate PRs for intake/taxonomy/enrichment/categories/regional gating/performance where possible. Do not merge a monolithic 4,000-profile application change untested.

## Expected deliverables
- `Tools/GlobalMarineImport/` with CLI, pure core functions, cache format, fixtures, mock-HTTP tests and README.
- `Data/GlobalMarine/CanonicalTaxa.csv` and `Data/GlobalMarine/OriginalNameCrosswalk.csv` with review status and stable IDs.
- `Data/GlobalMarine/EnrichmentEvidence.jsonl` with per-field species-specific citations.
- `Reports/GlobalMarine4000Intake.json`, `GlobalMarine4000Resolution.json`, `GlobalMarine4000Duplicates.csv`, `GlobalMarine4000Unresolved.csv`, `GlobalMarine4000RegionEligibility.json`, `GlobalMarine4000Regression.md`.
- Exact counts at each gate: 4,000 candidates, 529 reserve candidates, unique accepted marine species, rejected/unresolved, evidence-complete drafts, region-eligible, **human-verified**, publication-eligible.
- README with repeatable CLI commands for 250-record batches and re-run/replay from offline cache.

## Acceptance
No application pack or frozen expectation changes without justified, source-backed scope; no UUID churn; no unstated taxonomic synonym collisions; all HTTP failures recoverable; no automatic promotion. If 4,000 usable species cannot be verified, report the precise achieved count and gaps rather than manufacturing completeness. End with a PR summary stating exactly what is newly sourced, what is still draft, what is region-eligible, and what remains blocked.
