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
- **Colours and markings** are vocabulary terms found in the source description.
  Barbels come only from the structured barbel count.
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
