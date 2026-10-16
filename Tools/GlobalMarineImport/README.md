# Global marine intake and taxonomy staging

This pipeline has no application catalogue export. Source-list membership is not
accepted taxonomy, biological evidence, regional occurrence, or publication approval.
Install `Tools/CatalogImport/requirements.txt` (openpyxl); HTTP uses Python's standard
library. The two source CSVs in `Data/GlobalMarine/Sources` are verbatim pinned blobs,
with original MIT licenses retained. Intake checks their Git blob identities.

```sh
python3 Tools/GlobalMarineImport/intake.py
python3 Tools/GlobalMarineImport/process.py --batch 1 --dry-run --offline-cache-only
# 16 checkpoints, each at most 250 primary candidates:
for batch in $(seq 1 16); do
  python3 Tools/GlobalMarineImport/process.py --batch "$batch" --resume --offline-cache-only
done
python3 -m unittest discover -s Tools/GlobalMarineImport -p 'test_*.py' -v
```

Omit `--offline-cache-only` only on a host with working authorized HTTPS access to
`www.marinespecies.org`. Requests are sequential (maximum concurrency one), timeout
20 seconds, at most three attempts with bounded exponential backoff. Successes are
cached indefinitely for reproducibility. Transport/429/5xx/invalid-JSON failures
are cached diagnostically and retried online; offline execution never calls HTTP.
No fuzzy-match acceptance occurs. Empty responses, response-shape changes, ambiguous
matches, non-species ranks, and unconfirmed marine/extant flags remain pending with
distinct reasons. Accepted records, classification and all paginated synonyms must
agree before a taxon is counted confirmed. Synthetic mock IDs in tests are not data.

Every URL cache includes access timestamp, status, response fingerprint and payload.
Cache files are keyed by SHA-256 of the exact HTTPS URL. Corruption fails closed.
Archive a cache directory and use a fresh `--cache` path when intentionally updating
successful responses; never edit a cached payload or substitute HTML/search snippets
for REST JSON. Commit only actual source snapshots; an empty offline run creates no
fake responses. `--resume` replays successful cache entries and retries pending work,
retaining per-candidate checkpoints after each result. A checkpoint fingerprints all
input sources/packs; changed inputs require a fresh checkpoint directory. Partial
checkpoints preserve earlier completed work. `--dry-run` performs no writes/network.
`--report` selects a report directory, `--output` a staging directory. Cache and
checkpoint locations are independently configurable. Writes into `DiveID/` are denied.

Before any regional export, resolve the entire baseline scientific-name index with
`--queue baseline --batch N --resume` (250 names per batch; see resolution report's
baselineNames). This includes all workbook rows, every application pack and the 616
supplement. A name-less workbook identity stays preserved but cannot be taxonomically
resolved and blocks complete baseline collision clearance; printed names are never silently corrected. Exact verified workbook links
reuse UUIDs; conflicts stay unresolved. New UUIDs derive from candidate IDs in a fixed
namespace and survive spelling/synonym correction. Accepted-taxon collisions reuse
the first canonical/existing ID, retaining every original ID in the crosswalk.
Common-name similarity alone never merges taxa.

Only confirmed taxonomic collisions unlock `--queue reserve --batch N --resume`.
Reserves retain input rank and fill confirmed duplicate slots only; failures do not
create a quota to pad. They remain distinct from the 4,000 primary rows. All outputs
remain draft. `CanonicalTaxa.csv` contains only confirmed unique staging taxa, not
4,000 placeholder species. `OriginalNameCrosswalk.csv` preserves all 4,529 inputs;
resolution, duplicates and unresolved reports expose actual outcomes. Canonical
identity is still provisional against unresolved baseline synonyms, and regional
export remains blocked until that comparison and species-specific evidence finish.

Current access limitation: on 2026-10-15 the managed executor's enforced host list
omits WoRMS, and its HTTP proxy connection fails. A browser attempt to the exact REST
endpoint also failed. Offline checkpoints therefore mean cache missing, not "species
rejected". The webservice documentation was inspected at
https://www.marinespecies.org/aphia.php?p=webservice . Do not count mocked tests as
actual API verification. Research/evidence staging and publication review remain
separate from taxonomy confirmation.
