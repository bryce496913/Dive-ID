# Global marine intake and taxonomy staging

This pipeline has no application catalogue export. Source-list membership is not
accepted taxonomy, biological evidence, regional occurrence, or publication approval.
Install `Tools/CatalogImport/requirements.txt` (openpyxl); HTTP uses Python's standard
library. The two source CSVs in `Data/GlobalMarine/Sources` are verbatim pinned blobs,
with original MIT licenses retained. Intake checks their Git blob identities.
Existing schema-1 checkpoints cannot resume under schema 2; use the fresh-directory
migration commands below before processing any batches.

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
retaining per-candidate checkpoints after each result. `--dry-run` performs no
writes/network. `--report` selects a report directory, `--output` a staging
directory. Cache and checkpoint locations are independently configurable. Writes
into `DiveID/` are denied.

## Resume contract (checkpoint schema 2)

Every checkpoint stores an `inputManifest` and its SHA-256 `inputFingerprint`.
The manifest uses sorted repository-relative POSIX paths and canonical, sorted-key
JSON. Intake captures each file's bytes once, then uses those same in-memory bytes
for CSV/JSON parsing, workbook loading, source-blob validation and SHA-256 hashing.
It does not parse a path and later reread a replacement to hash it. This is a
per-file byte snapshot, not a transactional snapshot of a concurrently edited
repository; freeze the input tree while preparing a run.

The complete baseline input inventory is:

| Input | Why it affects compatibility |
|---|---|
| `Data/GlobalMarine/Expansion4000_CandidateQueue.csv` | Names, declared workbook links/provenance, source lineage, order, priority and draft constraints |
| `Data/GlobalMarine/Expansion4000_ReserveQueue.csv` | Reserve identities, order and collision replacements |
| `Data/GlobalMarine/Expansion4000_Audit.json` | Quotas, counts and pinned source-blob identities |
| `Data/GlobalMarine/Sources/reef.csv` and `asfis.csv` | Source-list name membership; Git blob checks also use captured bytes |
| `DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx` | All 1,650 UUID/name/provenance rows, including identities absent from packs |
| Every `DiveID/Resources/IdentificationPacks/*/*.json` | Discovered pack membership; Creatures scientific/accepted names, UUIDs and app-record membership. Manifests/other pack JSON remain conservatively fingerprinted as before. |
| `Data/TropicalPacific/TropicalPacificExpansion616.draft.json` | Supplement UUIDs, scientific names and accepted-name aliases, even if duplicated in the app pack |
| Manifest configuration | Decision-policy version, UUID namespace, WoRMS endpoint, batch size, workbook sheet/read flags, Python major/minor, Unicode and openpyxl versions |

`DECISION_POLICY` covers name normalization, taxonomy acceptance/interpretation,
identity linking, source checks, deduplication and reserve selection. Maintainers
must increment it whenever those decision rules change. Endpoint, namespace and
batch-size constants are shared with execution rather than duplicated in metadata.
Dependency/interpreter changes recorded above conservatively require a new run.

Required queue/audit/source/workbook files must exist. The supplement is optional:
its absent state is explicitly recorded as JSON `null`, not silently omitted.
Pack JSON membership is a discovered set, so adding/removing a pack or manifest
changes the set. Optional absence permits resume only while it stays absent;
later appearance, removal or changed bytes invalidate compatibility. Replacing a
file with identical bytes is compatible. Any changed bytes (even formatting) are
incompatible. Directory enumeration and dictionary order, absolute checkout
location, mtime, permissions and inode changes do not alter the fingerprint.
CSV row order remains significant because it determines batch/reserve priority.

Both primary/reserve and baseline checkpoint directories are fully validated
before results are reused, cache/network work starts, or any checkpoint/report/
output is written. A mismatch names the changed file/configuration keys. Restore
the exact inputs or use **fresh directories for both checkpoint stores**. Rejection
does not modify the old checkpoints, outputs or cache. Generation also validates
both stores before writing exports.

Schema-1 checkpoints, including all previously generated checkpoints that omitted
the supplement, are rejected explicitly. Their hashes cannot prove which
supplement bytes were used. Do not add a current hash to old checkpoints or simply
change their schema number. Archive them and rebuild decisions from the current
inputs, optionally replaying the existing integrity-checked raw response cache:

```sh
# Dry validation first; these paths must be fresh, not renamed old checkpoints.
python3 Tools/GlobalMarineImport/process.py --batch 1 --dry-run --offline-cache-only \
  --checkpoints /tmp/diveid-intake-v2/checkpoints \
  --baseline-checkpoints /tmp/diveid-intake-v2/baseline \
  --output /tmp/diveid-intake-v2/output --report /tmp/diveid-intake-v2/reports
# Then use the same paths for each batch/queue, with --resume instead of --dry-run.
# Remain offline for preparation; do not start live resolution without authorization.
```

Output paths, queue/batch selectors, dry-run/offline flags and retry timing are
execution controls rather than identity-baseline inputs. Queue/batch are stored
in each checkpoint; fixed batch size is in the manifest. Raw WoRMS cache files
are evolving execution evidence, not baseline inputs (otherwise every new HTTP
response would invalidate all batches). Their URL, schema and payload hash are
checked by the cache, and each resolved record retains its consumed response
evidence. Changing successful response snapshots is a separate new-run operation:
use fresh cache **and checkpoint directories**, as well as separate output paths.
Do not mix previously resolved batches with replacement response snapshots.

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
