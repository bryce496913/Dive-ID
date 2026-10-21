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
