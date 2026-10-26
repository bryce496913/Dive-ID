# FishBase / SeaLifeBase intake

Step 3 of `Docs/GlobalMarine4000ActivationPlan.md`. Resolves the 4,000 global
candidates and the existing app records to FishBase/SeaLifeBase species, using a
pinned release. It writes staging data only; nothing here changes the app's packs.

```sh
python3 -m pip install -r Tools/FishBaseIntake/requirements.txt   # pyarrow, real runs only
python3 Tools/FishBaseIntake/fetch.py              # download + verify the pinned tables (~76 MB)
python3 Tools/FishBaseIntake/resolve.py --offline  # resolve names from the verified cache
python3 -m unittest discover -s Tools/FishBaseIntake -p 'test_*.py' -v   # no pyarrow or network needed
```

**Pinned release.** `release_manifest.json` pins FishBase `v26.06` and SeaLifeBase
`v26.06` from the rOpenSci Source Cooperative bucket. Each table is pinned by S3 key,
size and ETag, which is the file's MD5. A download or cached file that doesn't match
fails closed and is never used. `--offline` never touches the network. The cache
(`Data/GlobalMarine/FishBase/cache/`) is git-ignored.

**Name resolution** (`resolve.py`), in order:
1. **exact:** a valid species name in exactly one database;
2. **synonym:** a species-level synonym (status synonym / accepted / provisionally
   accepted) that points to exactly one species;
3. **corrected:** a misspelling within a small edit distance of exactly one name that
   resolves under rules 1–2. The genus may differ by up to 2 edits with the same
   epithet, or the epithet by 1 edit within the same genus. Ties are never guessed.
   Per the owner's decision, misspellings are fixed; the original spelling stays in
   `correctedFrom`.

A synonym marked "ambiguous synonym", or one pointing to several species, is
**ambiguous** and flagged for the owner's full review. "Misapplied name" rows never
resolve a name. Anything else is **unresolved**.

**De-duplication.** Resolved inputs are grouped by database + SpecCode. An existing
app record keeps its identity; otherwise the first candidate in queue order does.
Every other member of the group gets `duplicateOf`.

**Outputs** (`Data/GlobalMarine/FishBase/`): `NameResolution.csv` has one row per
input; `NameResolutionSummary.json` holds the counts.

## Enrichment: draft records (`build.py`)

On a machine that can reach the pinned release and PyPI, `./Tools/FishBaseIntake/rebuild_drafts.sh`
does the network-dependent part in one go (throwaway venv with pyarrow, `fetch.py`,
`build.py --offline`, unit tests). It publishes nothing; run `publish_global.py` after.

```sh
python3 Tools/FishBaseIntake/build.py --offline              # after resolve.py, merge_plan.py, distribution.py
python3 Tools/FishBaseIntake/build.py --offline --batch 7    # rewrite one batch only
```

Builds one draft `LocalSpeciesProfile` per accepted taxon the merge plan keeps, under
the kept UUID. The rebuilt Tropical Pacific records keep their UUIDs, and none of
their field-guide text survives. The 8 Caribbean records are kept as they are (2 are
human-verified). Freshwater-only species are excluded.

- **Categories** come from the source taxonomy: Elasmobranchii are rays or sharks by
  order, Anguilliformes are eels, *Hippocampus* are seahorses, cephalopods go by order,
  and invertebrates go by class. The candidate queue is used only where taxonomy
  doesn't settle a category; disagreements are listed in the report.
- **Summary, distinguishing features, habitat text and the distribution summary** are
  short original wording assembled from source facts, never copied sentences.
- **Traits** (builder version 3, `traits.py`) come from the source text clause by clause:
  - **Text fields:** `morphdat.AddChars` and `RemarkSex` for appearance;
    `species.Comments`, `ecology.AddRems` and `AssociationsWith` for behaviour and habitat.
  - **Coded fields:** stripes, spots, coloured fin margins, barbels and night activity
    come from the structured morphdat and ecology codes.
  - **What comes out:** colours, markings, head and mouth clues ("Long snout", "Red
    teeth", "Prominent cheek spine"), fin clues ("Tall front dorsal fin", "Pink tail",
    "Black margins on the dorsal and anal fins"), tail shape, behaviours (schooling,
    solitary, anemone association) and features such as "Sways back and forth with
    the surge". All are short original wording.
  - **Negation:** a negated trait ("without spots", "lacks the snout", "barbels
    absent") is not asserted.
  - **Life stage and sex:** juvenile, male and female clauses become
    `appearanceVariants`; adult clauses feed the main profile.
  - **Ambiguity:** a hedged clause ("may", "sometimes", "with or without") or a
    comparative one ("males brighter than females") asserts nothing and raises a
    `trait_ambiguous` risk flag. So does a coded tail shape that disagrees with the
    description; neither shape is then asserted.
  - **Traceability:** every value is traced to its source field in `ClueTrace.json`,
    and each record's `dataSources[0].sourceFields` lists the fields it used.
    `BuildReport.json` counts the records each rule changes.
- **Similar species** come from `morphdat.SimilarSpecies1/2` when that species is in the
  pack.
- **Fields with no source stay empty or null.** For example, a species without any
  distribution gets an empty range and a `missing_required` risk flag.
- **`dataSources`** cites the SpecCode, species page, release, main reference and
  CC BY-NC 4.0 licence, and lists the `reviewedFields` the source supplied.

Batches are written resumably: a batch whose content is unchanged is not rewritten,
writes are atomic, and `Drafts/manifest.json` records each batch's SHA-256. Output is
deterministic. `BuildReport.json` gives field coverage and flag rates.
`RiskReport.json` gives each record's risk score, flags and batch, from
`Tools/CatalogReview/catalogue_validation.assess_risk`. The verbatim check compares
each record against the source passages it was built from.

## Writing the Global pack (`publish_global.py`)

```sh
python3 Tools/FishBaseIntake/publish_global.py   # after build.py
```

Writes the drafts into `DiveID/Resources/IdentificationPacks/Global/Creatures.json` and
derives every `PackManifest.json` count from the written records.

- **Left out:** records with a `missing_required` risk flag (the app rejects a pack
  containing one). They stay in staging.
- **Similar species** that point outside the written pack are dropped, along with
  `similarSpecies` in `reviewedFields` when none remain.
- **Drafts only.** Anything else stops the script. Release builds expose only
  verified records, so the pack stays Debug-only; `GlobalPackTests` proves it.
- **Validated before writing** with `Tools/CatalogReview/catalogue_validation.py`.
  Output is deterministic (one record per line), writes are atomic and an unchanged
  file is not rewritten.

`resolve.py` and `Tools/GlobalMarineImport/intake.py` never read the Global pack:
it is this pipeline's output, not an input.

## Distribution staging (`distribution.py`)

```sh
python3 Tools/FishBaseIntake/distribution.py --offline   # after resolve.py
```

Stages each resolved species' ocean basins, FAO areas and countries in
`Data/GlobalMarine/FishBase/Distribution.json`. The snapshot follows the WoRMS cache
rules:
- it records its exact source (the pinned table keys and ETags), when it was produced,
  its state and payload, and the payload's SHA-256;
- every read checks the schema, source and hash, and fails closed on any mismatch;
- a valid snapshot for the same source is reused; a new source needs a fresh output
  path, and a snapshot is never edited in place;
- writes are atomic.

Records with status questionable, misidentification, error, not established or
extirpated are kept with their status but never count towards ocean basins. Country
names and FAO area names are stored once, in shared lookups.

## Merge plan (`merge_plan.py`)

```sh
python3 Tools/FishBaseIntake/merge_plan.py   # exit status 2 when the plan has conflicts
```

Maps every existing app record and every primary candidate to one UUID per accepted
taxon (FishBase/SeaLifeBase SpecCode), never changing an existing UUID. The kept UUID
is, in order:
1. the existing app record's UUID;
2. otherwise the one workbook identity among the candidates (`IntakeCrosswalk.csv`);
3. otherwise the first candidate's UUID in queue order.

Other UUIDs are retired as aliases. These stop the plan for a decision:
- two existing app records for one taxon;
- two workbook identities for one taxon;
- one UUID claimed by two taxa.

Outputs: `MergePlan.csv` and `MergePlanReport.json`. `build.py` gives candidates their
crosswalk UUID, so workbook identities are kept.

## Owner additions (`Data/GlobalMarine/OwnerAdditions.csv`)

Species the owner asks for after the build batches were reviewed. One row each:
`additionID`, `scientificNameInput`, optional `commonName` (the name the owner asked for;
blank uses the source's main name), optional `preferredAliases` (`;`-separated, each an
English name in the source), `batch`, `speciesID` (uuid5 of the addition ID in the
`Tools/GlobalMarineImport/intake.py` namespace), who asked and when.

- `resolve.py` and `merge_plan.py` take them after every candidate, so an addition of a
  species the pack already holds only retires.
- `distribution.py` stages species resolved after `Distribution.json` was written in
  `DistributionAdditions.json` (same source, same checks); `Distribution.json` is never
  rewritten. A later addition that isn't covered needs a fresh output path.
- `build.py` puts each addition in the batch its row names, which must come after every
  build batch, so build batches never change. When `commonName` is set, the source's main
  name becomes an alias; preferred aliases come first. An addition's common name and
  preferred aliases belong to it alone (an alias naming it on another record is dropped),
  it takes no alias another record already has, it may not share another record's common
  name (the build stops), and existing records gain no similar-species link to it.
  `RiskReport.json` marks each with `ownerAddition`.
- They are drafts like every other record. Prepare their batch with
  `global_batches.py prepare --batch N`; records whose content the addition changed (an
  alias dropped) need `prepare --batch M --rereview`.


**Dive regions** (`derive_regions.py`). Writes the four regions drawn from Global
(Tropical Atlantic, Indo-Pacific, Pacific Coast, Mediterranean) as Global record-ID
lists plus manifests under `DiveID/Resources/IdentificationPacks/`, from each record's
FAO areas and the staged distribution's counted country rows. Run it after
`publish_global.py`; `--check` (and `test_derive_regions.py`) fails while they are stale.
