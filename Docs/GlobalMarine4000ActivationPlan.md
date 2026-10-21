# Global Marine 4000 activation plan

Status: **planning only**. This document records owner decisions and research findings.
It changes no app code, catalogue data, ranking behaviour or import tooling. All 4,000
candidates in `Data/GlobalMarine/Expansion4000_CandidateQueue.csv` remain `draft` and
`publicationEligible=false`.

Research date: 2026-10-21.

## 1. Owner decisions (recorded verbatim, 2026-10-21)

1. Content source: FishBase (fish) and SeaLifeBase (invertebrates, turtles, other non-fish). Dive ID is free, with no ads or in-app purchases.
2. One global pack containing all records: the 4,000 candidates plus the existing 1,008, with no duplicates. Location is a ranking signal, never a filter, so rare out-of-range sightings can still match.
3. Review: I read every flagged record plus a seeded random sample of 30 unflagged records per batch of 250. Any error in the sample sends the batch back.

## 2. Licence and attribution

### 2.1 What the sources say

**Verification limit:** this environment's network policy blocks every FishBase and
SeaLifeBase host (`fishbase.se`, `.org`, `.de`, `.ca`, `mnhn.fr`, `sealifebase.se`, `.org`,
`.ca`) and the Web Archive. The website wording below comes from search-engine extracts
of the cited pages, not from a direct page load. **Before publication, a person must open
the two citation pages and confirm the wording and the current version stamp.**

| | FishBase | SeaLifeBase |
|---|---|---|
| Licence of text, numbers and maps | "This work is licensed under Attribution-NonCommercial 4.0 International" (CC BY-NC 4.0) | Same statement, CC BY-NC 4.0 |
| Self-citation | `Froese, R. and D. Pauly. Editors. 2026. FishBase. World Wide Web electronic publication. www.fishbase.org, version (02/2026).` | `Palomares, M.L.D. and D. Pauly. Editors. 2026. SeaLifeBase. World Wide Web electronic publication. www.sealifebase.org, version (06/2026).` |
| Per-record credit | "To give due credit to the original authors, please cite data taken from FishBase by Main Ref. and/or Data Ref. of the respective record." | Same practice (each record carries `…Ref`/`…RefNo` reference numbers) |
| Reuse condition | Non-commercial use of text, numbers and maps is welcome "provided they are clearly identified as coming from FishBase, with a backward link to the respective source page" | Same wording for SeaLifeBase |
| Photos and drawings | "belong to the indicated persons or organizations and have their own copyright statements" | Same; licensed per image |
| Earlier licence | CC BY-NC 3.0 Unported (2016–2019 archives) | CC BY-NC 3.0 Unported |

Pages cited:
- FishBase citation page: <https://www.fishbase.se/summary/citation.php> (mirrors: <https://fishbase.ca/summary/citation.php>, <https://fishbase.net.br/summary/citation.php>)
- SeaLifeBase: <https://www.sealifebase.se/search.php>, citation page `https://www.sealifebase.se/summary/citation.php`
- Licence legal code: <https://creativecommons.org/licenses/by-nc/4.0/legalcode.en>
- Older 3.0 licence: <https://zenodo.org/records/2577515>, <https://github.com/globalbioticinteractions/sealifebase>

**Verified directly:** the bulk-data mirror's dataset card,
`s3://us-west-2.opendata.source.coop/cboettig/fishbase/README.md`, says
`license: cc-by-nc-4.0`, "**License:** CC-BY-NC, FishBase.org Team", and "Reuse of
this data is not licensed for commerical applications. Developers should contact the
FishBase team directly." The `rfishbase` R package itself is CC0
(`DESCRIPTION: License: CC0`). That covers only the software, not the data it downloads.

### 2.2 What this means for Dive ID

- **Non-commercial.** CC BY-NC 4.0 allows use "not primarily intended for or directed
  towards commercial advantage or monetary compensation" (§1(i)). A free app with no ads
  and no in-app purchases is the case the licence is written for. That is a reading of
  the licence, not legal advice. The data mirror explicitly tells developers to contact
  the FishBase team. **Recommendation:** get written confirmation from the FishBase /
  SeaLifeBase team before release. The address they publish is in the `rfishbase` README
  (*"A message from the FishBase team"*). Any future paid tier, ads or sponsorship would
  need a separate licence.
- **Required attribution** (CC BY-NC 4.0 §3(a)):
  - credit the creators (the database editors, and Main/Data Ref for each record);
  - a licence notice with a link to the licence;
  - a link to each record's source page;
  - a statement that Dive ID modified the content (normalised, summarised, mapped to
    Dive ID vocabulary).

  FishBase additionally asks for "a backward link to the respective source page".
- **Where attribution fits in the current model.** `SpeciesDataSourceReference` already has
  `stableSourceID` (for example `FishBase SpecCode 4589`), `sourceURL` (the species summary
  page), `citationReference` (Main Ref), `sourceLicense` (`CC BY-NC 4.0`) and
  `accessedDate`. The app also needs a catalogue-level credits/licence screen that shows
  both self-citations and the release version. It doesn't have one yet.
- **No images from these sources by default.** Each photo has its own rights holder.
  `picturesmain` lists them, but every image needs its own licence check. Bundled images
  stay out of scope unless decided otherwise (§7).
- **Share-alike does not apply** (BY-NC, not BY-NC-SA). However, derived catalogue records
  remain CC BY-NC content wherever they are redistributed, including this repository and
  the app bundle.

### 2.3 Conflict with the existing 1,008 records

- **Tropical Pacific (1,000 records):** every record's `dataSources` names *Reef Fish
  Identification: Tropical Pacific* (Allen, Steene, Humann & DeLoach, 2003), with
  `sourceLicense: "Copyright © New World Publications, Inc. 2003. All rights reserved."`.
  Four records also cite a CC BY 3.0 AU source. Decision 1 makes FishBase/SeaLifeBase the
  content source. The records' text and fields therefore need to be rebuilt from
  FishBase/SeaLifeBase before they join a published global pack, or the owner must
  confirm the rights to the current text.
- **Caribbean (8 records):** these already cite "FishBase species summary" (plus Florida
  Museum profiles for 4). None has `sourceLicense` set. Each of the 8 bundled images has
  its own image credit.

## 3. Supported bulk access route

Use the **published Parquet release** that `rfishbase` 5.x reads, not HTML scraping.

- **Host:** Source Cooperative public bucket `us-west-2.opendata.source.coop`, layout
  `cboettig/fishbase/{fb|slb}/v<YY.MM>/parquet/<table>.parquet` (`fb` = FishBase,
  `slb` = SeaLifeBase). Per its dataset card, each release is "raw parquet exports from
  the MySQL database backend", produced from a dump the FishBase team supplies about once
  a year.
- **How to fetch:** direct HTTPS GET on
  `https://s3.us-west-2.amazonaws.com/us-west-2.opendata.source.coop/<key>` worked from
  this environment. The `https://data.source.coop/<key>` URLs that `rfishbase` builds are
  blocked here (proxy 403), as are `source.coop` and `docs.ropensci.org`. Python with
  `pyarrow` is enough to read the files; R is not required.
- **Releases available (bucket listing, 2026-10-21):**
  - FishBase: `v19.04 v21.06 v23.01 v23.05 v24.07 v25.04 v26.06`
  - SeaLifeBase: `v19.04 v23.01 v23.05 v24.07 v25.04 v26.06`

  The dataset card says the current releases are `fb/v26.07` and `slb/v26.04`, but
  neither prefix exists in the bucket. Pin to what the listing shows.
- **Recommended pin:** `fb/v26.06` and `slb/v26.06`. Pin each table by its S3 key plus
  ETag. I confirmed that ETag equals the file's MD5: downloads of `fb/species` and
  `slb/species` hashed to `0208d896…4330` and `f176abbb…5f06a`, the same as their ETags.
  Nothing documents whether a published release can be re-uploaded, so the ETag check is
  what detects a replaced object. Objects in `v26.06` were last modified on 2026-09-04.
  The website version stamps (02/2026 and 06/2026) need not match the dump month, so
  record both.

### 3.1 Tables needed (join key `SpecCode`, spelled `Speccode` in some tables; `StockCode` for stocks)

| Need | FishBase / SeaLifeBase table | Columns (verified schema, v26.06) |
|---|---|---|
| Scientific name, authority, family/genus | `species` (+ `genera`, `families`, `orders`, `classes`) | `Genus`, `Species`, `Author`, `FamCode`, `GenCode` |
| Common names | `comnames`; preferred English name in `species.FBname` | `ComName`, `Language`, `NameType`, `PreferredName`, `C_Code` |
| Synonyms / name resolution | `synonyms` | `SynGenus`, `SynSpecies`, `SpecCode`, `Status`, `Valid` (slb) |
| Size | `species` (+ `popll`, `poplw` if needed) | `Length`, `LTypeMaxM` (TL/SL/FL/WD/…), `CommonLength`, `LTypeComM`, `MaxLengthRef`, `CommonLengthRef` |
| Depth | `species` | `DepthRangeShallow`, `DepthRangeDeep`, `DepthRangeComShallow`, `DepthRangeComDeep`, `DepthRangeRef` |
| Habitat (structured) | `ecology` | booleans incl. `CoralReefs`, `Sand`, `Rubble`, `SeaGrassBeds`, `Mangroves`, `Lagoons`, `DropOffs`, `Burrows`, `Epipelagic`, `Oceanic`, `Intertidal` |
| Habitat (coarse) | `species` | `DemersPelag` (reef-associated, demersal, pelagic-neritic, benthic…), `Saltwater` |
| Distribution text | `stocks` | `StockDefs` (for example "Western Atlantic: New York, USA and Bermuda to Mexico.") |
| Distribution (structured) | `faoareas` → `faoarref`; `country` → `countref`; `ecosystem` → `ecosystemref` | `AreaCode`/`FAO`; `C_Code`/`PAESE`, `Status`; `E_CODE`/`EcosystemName`, `MEOW` |
| Bounding box | `stocks` | `Northernmost`, `Southermost`, `Westernmost`, `Easternmost` |
| Morphology | `morphdat` | `BodyShapeI/II`, `CShape`, `CaudalFinI/II`, `TypeofMouth`, `PosofMouth`, `Forehead`, `DorsalSpinesMin/Max`, `Notched`, stripe/spot fields (`HorStripesTTI`, `SpotsTTI`, …), `BarbelsNo`, `SexColors` |
| Diagnosis text | `morphdat` | `AddChars` (for example "Back elevated; snout long and tapering…") |
| Biology/description text | `species` | `Comments` (for example "Found in quiet waters with rocky bottoms…") |
| Similar species | `morphdat` | `SimilarSpecies1/2` (SpecCode), `SimilarSpec1Remarks/2Remarks` |
| Behaviour | `ecology` | `Schooling`, `Shoaling`, `Solitary`, `Benthic`, `Burrows`, `Symbiosis`, `AssociationsWith`, `FeedingType` |
| Hazards | `species` | `Dangerous` (harmless, venomous, traumatogenic, reports of ciguatera…) |
| References | `refrens` | resolves every `…Ref`/`…RefNo` to a citation |
| Images (excluded by default) | `picturesmain` | per-photo author/licence |

### 3.2 Coverage against the actual candidates (v26.06, exact `Genus Species` match)

| | 4,000 candidates | Existing 1,008 |
|---|---:|---:|
| Matched in FishBase / SeaLifeBase | 3,503 / 296 | 702 / 1 |
| Unmatched → resolvable via `synonyms` | 197 of 201 (17 ambiguous) | 153 of 305 (25 ambiguous) |
| Still unmatched | 4 (`Octopus crusoe`, `Phyllonotus duplex`, `Pattalus mollis`, `Crassostrea mangle`) | 152 |
| English common name (`comnames`) | 3,380 | 694 |
| Max length | 3,637 | 696 |
| Depth range (shallow and deep) | 2,894 | 651 |
| `species.Comments` text | 3,473 | 696 |
| `ecology` row | 2,438 | 588 |
| `morphdat` row / `AddChars` text | 2,937 / 2,391 | 678 / 650 |
| FAO areas / country rows | 3,797 / 3,794 | 703 / 703 |

The existing records' 152 unmatched names are mostly **misspellings in the current data**,
for example `Jascyllus melanurus`, `Shrysiptera hemicyanea`, `Monodactyus argenteus`,
`Jectropomus laevis` and `Antennanius dorehensis`. They need correction before matching.
The intake pipeline deliberately never auto-corrects names. Exact-name overlap between the
candidates and the existing records is 0, but accepted-name collisions still need the
WoRMS/synonym deduplication the intake pipeline already performs.

## 4. Field mapping

| App field (`LocalSpeciesProfile` / `Creatures.json`) | Source | Notes |
|---|---|---|
| `scientificName`, `taxonomy.genus/family/order/taxonomicClass`, `scientificNameAuthority` | `species` + `genera`/`families`/`orders`/`classes` | |
| `taxonomy.wormsAphiaID`, `acceptedScientificName` | **none** in FishBase/SeaLifeBase | Comes from the existing WoRMS pipeline |
| `commonName`, `aliases` | `species.FBname`, `comnames` (English) | Aliases may also take scientific synonyms |
| `categories` | derived from taxonomy (Elasmobranchii → shark/ray, Anguilliformes → eel, Syngnathidae → seahorse, …) | No column; 59 candidates are `needs_taxon_group` |
| `minimumSizeCentimeters`, `maximumSizeCentimeters`, `measurements` | `species.Length`/`LTypeMaxM`, `CommonLength`/`LTypeComM` | **Schema gap:** `SpeciesMeasurementType` has only TL/FL/disc width/carapace length. Among candidates, 956 use SL, and invertebrates use SHL/CW/ML/BL/DL. |
| `minimumDepthMeters`, `maximumDepthMeters` | `DepthRangeShallow/Deep` (or `…Com…` for the usual range) | Choose which range to use (§7) |
| `habitats` | `ecology` booleans + `DemersPelag`; shallow/deep derived from depth | **No source** for `wreck`, `surface`; `anemone` only via the `AssociationsWith` text |
| `regions`, `subregions` | `faoareas`, `country` (`Status` native/endemic/introduced), `ecosystem` (`MEOW`) | Exclude `country.Status` = questionable / misidentification / error |
| `geographicRange` | `stocks.StockDefs` | Text |
| `regionalOccurrence` | partial: `country.Status` (`introduced`), `country.Abundance` | No global common/rare scale |
| `bodyShapes` | `species`/`morphdat.BodyShapeI` (fusiform / elongated / short and/or deep / eel-like) | Needs a mapping onto vocabulary; empty for SeaLifeBase |
| `markings` | `morphdat` stripe/spot/barbel fields, `AddChars` | Text extraction needed |
| `colors` | **no structured source**: free text only (`AddChars`, `Comments`, `SexColors`) | Every colour term needs extraction + review |
| `tailShape` | `morphdat.CShape`, `CaudalFinI/II` | Missing for ~40% of fish candidates |
| `mouthAndHeadShape` | `morphdat.TypeofMouth`, `PosofMouth`, `Forehead` | |
| `finAndSpineClues` | `morphdat` dorsal/anal spines, `Notched`, `Adifin` | |
| `behaviors` | `ecology` schooling/solitary/benthic/burrows/symbiosis, `FeedingType` | **No source** for hovering, hiding, resting, cleaning (text only) |
| `summary`, `distinguishingFeatures`, `typicalHabitat` | `species.Comments`, `morphdat.AddChars` | Must be rewritten/summarised, and marked as modified |
| `similarSpecies` | `morphdat.SimilarSpecies1/2` + remarks | Sparse (280 fish candidates) |
| `appearanceVariants` (juvenile/adult/phase) | partial: `SexColors`, `Females`/`Males`, `RemarkSex` | No structured life-stage colouration |
| `cautions` | `species.Dangerous` | |
| `dataSources` | SpecCode, species page URL, `refrens` for Main/Data Ref | §2.2 |
| `bundledImage`, `imageAssetName` | **none by default** | Per-photo licences (§2.2) |
| `review` | **none** | Owner review process (decision 3) |
| `keywords` | derived | |

`CatalogueVocabulary.regions` currently holds 25 Caribbean/Atlantic/Pacific terms. A global
pack needs a larger, hierarchical region vocabulary. FAO major areas plus MEOW ecoregions
(`ecosystemref.MEOW`) are the natural backbone.

## 5. How location affects ranking today

Location is extracted only from a fixed name list:
`RegionCompatibilityResolver.locationNames` = `CatalogueVocabulary.regions` plus four pack
aliases. The resolver returns `compatible`, `conflicting` or `unspecified` through a small
hand-written parent map (for example bonaire → caribbean → western atlantic → atlantic).
The result is used in three places:

1. **Pack-level hard stop.** In `LocalMarineLifeIdentificationService`, if the description
   names a place that conflicts with the selected pack's `regionAliases`, the search fails
   with `regionMismatch` and returns **no results at all**. That is a filter.
2. **Per-species score.** In `LocalSpeciesRanker`, compatible adds +5 and conflicting adds
   **−12**. The eligibility threshold is 4. An out-of-range species therefore needs at
   least 16 points from other clues to stay listed, for example category 6 + habitat 4 +
   marking 4 + colour 3. A typical out-of-range description drops it. That is
   effectively a filter. An exact common/scientific name bypasses the threshold.
3. **Supporting signals.** `regionalOccurrence` adds an ordering prior (common +3 …
   rare −3) without affecting eligibility. A mentioned region also counts as one clue
   group when grading how informative the description is. `SpeciesSearchDocument`
   indexes regions and range text for BM25.

`Docs/HybridRankingContract.md` states that "structured region, animal-group, size, and
habitat conflicts are still scored after provisional admission and can lower or remove a
candidate". Today, region can remove.

Also note: none of the 1,000 Tropical Pacific records has `regions` set, so the
per-species location signal currently never applies to them.

### 5.1 Changes needed for "location boosts, never excludes"

1. Remove the pack-level `regionMismatch` stop for the global pack. With one global pack
   there is no selected region to conflict with.
2. Make a region conflict have no effect: compute eligibility without the region term,
   and apply location only as an ordering boost. Per decision 11, an out-of-range species
   gets no penalty at all; it simply gets no boost.
3. Keep a match as a boost, and grade it by evidence: native/endemic in the named area >
   neighbouring area > introduced. Never treat `questionable`/`misidentification`/`error`
   rows as support.
4. Replace the hand-written parent map and the 25-term vocabulary with data-backed areas
   (FAO area + MEOW ecoregion + country) and a broader recogniser for place names in
   descriptions.
5. Explanations: show "outside known range" as a caution on the result, not as a removed
   result.
6. Update `HybridRankingContract.md` and the ranking/region tests (including the existing
   `regionMismatch` and conflict tests) to the new contract.
7. Per decision 10, turn the dive-region selection into an optional "where are you
   diving?" setting that boosts species recorded in that region. It no longer switches
   packs or blocks searches. This replaces the two-pack `SelectedPackState` flow: there is
   always one global catalogue, and "no region selected" becomes a valid state.

## 6. Review process (decision 3) against the existing pipeline

`Tools/GlobalMarineImport` already processes 16 checkpoints of at most 250 primary
candidates, which matches the review batch size. To implement decision 3:
- each checkpoint records the sample seed and the 30 sampled IDs;
- the rules for what "flagged" means are written down and versioned (§7);
- a failed sample marks the whole batch as returned, with the reason recorded.

## 7. Follow-up decisions

### 7.1 Owner answers (2026-10-21)

| # | Question | Owner decision |
|---|---|---|
| 1 | Licence | The catalogue stays CC BY-NC. No paid tier, ads or sponsorship without a new licence. |
| 2 | Tropical Pacific text | Rebuild all 1,000 records from FishBase/SeaLifeBase, so every record has the same sourcing. |
| 3 | Misspelled existing names | Fix them. Keep the original spelling in the crosswalk. |
| 4 | Release pin | Pin `fb/v26.06` and `slb/v26.06`. |
| 5 | Measurement types | Add Standard Length and the invertebrate length types to the schema. |
| 6 | Size and depth ranges | Match on the full recorded ranges. |
| 7 | Images | No images yet. |
| 8 | Colours and markings | Extract them from description text, then review them. |
| 10 | Region UI | Keep an optional "where are you diving?" selection. It boosts species from that region when finding a match. |
| 11 | Out-of-range species | No effect at all. |
| 12 | Attribution placement | A catalogue credits screen plus a source link on each species detail screen. |

Consequences for §5.1: a region conflict changes neither eligibility nor ordering.
Location only adds a boost, both from a place named in the description and from the
optional dive-region selection. The pack-level `regionMismatch` stop goes away. The
dive-region selection stays in the UI, but as an optional boost rather than a pack
switch.

### 7.2 Review flags and data rules (owner answers, 2026-10-21)

A record is **flagged** (read in full) only if its name matched through a synonym that
points to more than one species (17 candidates). Everything else is covered by the
seeded sample of 30 per batch of 250. The other conditions considered are handled as
data rules, not flags:

| Condition | Rule |
|---|---|
| No animal group (59 candidates) | Assign a group from the record's taxonomy and fix it. Not flagged. |
| No size or depth data | Leave the field blank. Not flagged. |
| Hazard other than "harmless" | Not flagged. |
| Range is free text only, with no structured area | Not flagged. |
| Misspelled existing name (152) | Correct it, keep the original in the crosswalk. Not flagged. |
| Extracted colours/markings | Not flagged; covered by the sample. The owner did not object to this suggestion. |

The 59 ungrouped candidates are all invertebrates with known families:
- sea cucumbers: 39 (Holothuriidae, Stichopodidae, Cucumariidae, Phyllophoridae)
- sea urchins: 7 (Strongylocentrotidae, Echinidae, Arbaciidae, Toxopneustidae)
- jellyfish: 5 (Pelagiidae, Ulmaridae, Stomolophidae)
- marine worms: 6 (Arenicolidae, Onuphidae, Glyceridae, Nereididae, Lumbrineridae, Urechidae)
- horseshoe crab: 1 (Limulidae)
- sea squirt: 1 (Pyuridae)

None of these groups exists in `CatalogueVocabulary.categories` today, so fixing them
requires new categories (still open below).

### 7.3 Licence confirmation and new categories (2026-10-21)

- **Licence confirmation:** the owner sent the Appendix A email on 2026-10-21. No reply
  yet. Per the owner, work continues meanwhile; the reply is not a blocker. The owner
  expects "yes" to the non-commercial question and "no" to extra attribution. Those are
  expectations, **not FishBase's reply**. Record the actual reply here when it arrives.
- **Errors found during review:** fix them in Dive ID's records; don't report them to
  FishBase (owner decision).
- **New categories:** added `sea cucumber`, `sea urchin`, `jellyfish`, `worm`,
  `sea squirt` and `horseshoe crab`, as proposed. The owner did not object, and they are
  easy to rename.

### 7.4 Original question list

### 7.3 Original question list

1. **Licence confirmation:** will you ask the FishBase/SeaLifeBase team for written
   confirmation that free, ad-free, IAP-free distribution of derived records in an App
   Store app counts as non-commercial? Do you accept that the catalogue stays CC BY-NC
   (no paid tier, ads or sponsorship later without a new licence)?
2. **Existing Tropical Pacific text:** rebuild all 1,000 records from
   FishBase/SeaLifeBase, or keep the current text? It is marked "All rights reserved" by
   New World Publications, so keeping it needs a rights confirmation.
3. **Misspelled existing names (152):** may names be corrected to the accepted spelling,
   with the original kept in a crosswalk? The intake currently never auto-corrects.
4. **Release pin:** pin `fb/v26.06` + `slb/v26.06` (the latest present in the bucket)?
5. **Measurement types:** add Standard Length and the invertebrate length types
   (shell length, carapace width, mantle length, body length, disc length) to the schema,
   or convert/omit them?
6. **Depth and size ranges:** use the full recorded range or the "usual" range (common
   depth, common length) for matching?
7. **Images:** ship no photos for new records, or allow per-image licence-checked photos
   from `picturesmain`?
8. **Colours and visual text:** FishBase has no structured colours. Is
   extracting colours/markings from `AddChars`/`Comments`, then reviewing them, acceptable?
   Are any of those generated fields "flagged" by definition?
9. **What counts as "flagged" for review:** for example ambiguous synonym matches (17),
   `needs_taxon_group` (59), missing size/depth, `Dangerous` ≠ harmless, extracted
   colours, and range text with no structured area.
10. **Region UI:** remove dive-region selection, or keep it as an optional boost?
11. **Out-of-range weighting:** no effect at all, or a small ordering-only penalty?
12. **Attribution placement:** a catalogue credits screen plus per-species source links on
    the species detail screen. Is that acceptable?

## 8. Build plan

Each step is a separate, reviewable change.

1. **Schema** (done): new length bases and animal groups, in Swift, the Python validator
   and the parser.
2. **Location as a boost** (§5.1), ranker part done: the −12 conflict is gone, an
   out-of-range species gets no effect, and `SpeciesRankingInput.preferredRegions`
   gives an ordering-only boost. The pack-level `regionMismatch` stop stays until step 6:
   while separate region packs exist, removing it would silently return the wrong
   region's species. The app passes the dive-region choice as `preferredRegions` in
   step 6.
3. **FishBase/SeaLifeBase intake** (`Tools/`): download the pinned `v26.06` tables and
   verify each ETag/MD5; resolve names (exact match, then synonyms, flagging ambiguous
   matches); dedupe the 4,000 + 1,008 records by SpecCode and accepted name; fix
   misspelled names, keeping originals in the crosswalk.
4. **Record builder**: map tables to `LocalSpeciesProfile` (§4). Includes animal group
   from taxonomy, full size/depth ranges with their length basis, regions from FAO
   area/country/MEOW, range text from `StockDefs`, and summary/features rewritten from
   `Comments`/`AddChars` with colours and markings extracted for review. `dataSources`
   carries SpecCode, page URL, Main Ref and CC BY-NC 4.0. No images.
5. **Review batches**: 250 records per batch. Read flagged records in full, plus a
   seeded sample of 30; any error in the sample returns the batch.
6. **Global pack + app**: one global pack replaces Caribbean/Tropical Pacific, with a
   credits screen and a source link on each species detail screen.

## Appendix A. Licence confirmation email (draft, not sent)

**To:** fishbase@q-quatics.org

That address comes from the FishBase team's message in the `rfishbase` README
(<https://github.com/ropensci/rfishbase>). It invites reports to "FishBase and
SeaLifeBase team" and is the only contact address published in the sources checked here.
The FishBase and SeaLifeBase websites were not reachable from this environment, so check
their "Contact us" pages before sending in case a licensing contact is listed.

**Subject:** Licence confirmation: non-commercial use of FishBase and SeaLifeBase data in a free dive app

> Dear FishBase and SeaLifeBase team,
>
> I am developing Dive ID, a free iPhone app that helps recreational divers identify
> marine life they saw, from a written description. It works offline. Dive ID has no
> advertising, no in-app purchases, no paid tier and no sponsorship, and I do not plan to
> add any.
>
> I would like to build its species catalogue (about 5,000 marine species: fishes,
> invertebrates and sea turtles) from FishBase and SeaLifeBase, using the database
> snapshots published for rfishbase (FishBase v26.06 and SeaLifeBase v26.06). I would use
> text and numeric data such as names, size, depth, habitat, distribution, morphology and
> descriptions. I would summarise and normalise them for search, and I would not use any
> photographs or drawings.
>
> I understand this content is licensed under CC BY-NC 4.0. My plan is:
> - keep the derived catalogue under CC BY-NC 4.0, never use it commercially, and seek a
>   separate licence before any paid feature, advertising or sponsorship;
> - show a credits screen in the app with your recommended citations for FishBase and
>   SeaLifeBase (with version), the licence and a link to it, and a note that the data
>   was adapted;
> - link each species in the app to its FishBase or SeaLifeBase species page and cite its
>   Main Ref.
>
> Could you please confirm:
> 1. that distributing this free app, without ads or purchases, through the Apple App
>    Store is non-commercial use you are happy with;
> 2. whether you require anything beyond the attribution above;
> 3. whether you would like me to report errors I find while reviewing records, and in
>    what format.
>
> Thank you for maintaining these resources.
>
> Kind regards,
> Bryce Cameron
> Dive ID

