# Species photos

Stage 1 of adding licensed species photos to the Global catalogue. It covers the intake
tool, a reviewed photo manifest and attribution. Bundling beyond the end-to-end proof is
a later decision (see [size projection](#size)).

```sh
python3 -m pip install -r Tools/SpeciesPhotos/requirements.txt   # pyarrow, Pillow; real runs only
python3 Tools/SpeciesPhotos/fetch_fishbase_pictures.py         # pinned FishBase/SeaLifeBase picture tables (~3 MB)
python3 Tools/SpeciesPhotos/species_photos.py                  # resolve -> select -> manifest (about 3 h uncached)
python3 Tools/SpeciesPhotos/species_photos.py --offline        # rerun from the cache: no requests, same manifest
python3 Tools/SpeciesPhotos/species_photos.py --interval 5     # slower, if iNaturalist answers 429 (rate limited)
python3 Tools/SpeciesPhotos/species_photos.py --cached-only    # no requests: every species already cached; the rest counted as notYetFetched
python3 Tools/SpeciesPhotos/thumbnails.py --species <id> ...   # 400 px thumbnails for the photos to review
python3 Tools/SpeciesPhotos/thumbnails.py --all --first-only   # the photo the app shows, for every species in the manifest
python3 Tools/CatalogReview/photo_batches.py prepare <batch-id> --species <id> ...
python3 -m unittest discover -s Tools/SpeciesPhotos -p 'test_*.py' -v   # no network, pyarrow or Pillow needed
```

## Licence policy

`photo_policy.json` is the owner's policy (2026-10-27), enforced in `licences.py`:

| Licence | Outcome |
|---|---|
| CC0, CC BY, CC BY-NC | **allowed** (Dive ID is non-commercial; Global text is already CC BY-NC) |
| CC BY-SA, CC BY-NC-SA | **later decision**: not selected; counted per species in the coverage report |
| CC BY-ND, CC BY-NC-ND | **excluded**: thumbnails are resized, which ND forbids. The policy loader refuses an ND licence in the allowed list |
| all rights reserved, missing, unknown | **excluded** |

The policy is configurable (`--policy`), but a licence can't be both allowed and held for
later, and an unknown licence code is an error.

## Sources

**iNaturalist (primary).** `species_photos.py` uses the public API through `inat.py`. The
client sends at most one request per second, identifies the app in its User-Agent, retries
429/5xx with back-off and caches every response under `Data/SpeciesPhotos/cache/`
(git-ignored). Cached responses keep only the fields the pipeline reads; a full page is about
1.5 MB, so untrimmed the cache wouldn't fit on disk. The open-data metadata export would
avoid the API, but it's several gigabytes to download and unpack. That doesn't fit the build
Mac either, so the throttled, cached API is used instead.

1. **Resolve.** Each Global species is matched by scientific name to an active
   species-rank taxon, and the taxon ID is recorded. A name iNaturalist knows only as a
   synonym (`matched_term`), several equal matches, or no match is **flagged and never
   guessed**. Flagged species get no photo.
2. **Select.** The pipeline queries research-grade observations with an allowed photo
   licence, ordered by votes. It keeps photos that are wild (not captive), not hidden or
   flagged, at least 800 px on the longest side and from a named creator. Landscape
   photos come first (`width >= 1.1 x height`), as a stand-in for a lateral, whole-animal
   view. The final choice of view is the reviewer's. Each species keeps at most two photos,
   from different observers. `Data/SpeciesPhotos/PhotoChoices.json` records the reviewer's
   own picks, which rank first if they pass every filter, and rejected photos, which are
   never selected again. Choosing a photo there doesn't approve it; review still does.
3. **Manifest.** The pipeline writes `Data/SpeciesPhotos/PhotoManifest.json`, sorted with
   fixed keys. Each photo records:
   - creator name;
   - licence code, name and URL;
   - source name;
   - source page (the photo page), photo URL and observation URL;
   - photo, observation and taxon IDs;
   - observation and retrieval dates;
   - `review: pending`.

   The coverage report goes to `Reports/SpeciesPhotoCoverage.json`.

**FishBase / SeaLifeBase (fallback).** This is only for species with no allowed
iNaturalist photo. Their CC BY-NC data licence does not cover photos.
`fetch_fishbase_pictures.py` downloads only the pinned v26.06 picture tables (photo
metadata, checked by size and MD5); no photo is ever downloaded. A photo would qualify only
if it stated an allowed licence, and none in the tables does. Their `Copyright` values are
"non-commercial use", "permission required", "free use" or blank. So each such species
goes to `Data/SpeciesPhotos/PermissionNeeded.csv` with the photographer and photo page.
Rows marked public domain go there as "confirm public domain". The photo enters only after
the owner records written permission from the photographer.

## Review

Photos are reviewed like records (`Tools/CatalogReview/photo_batches.py`, following
`global_batches.py`):

1. `prepare` writes a manifest that fingerprints each photo's attribution and the exact
   thumbnail bytes, and an HTML page in `Reports/PhotoReview/` that shows each photo
   beside the species' common name, scientific name and distinguishing features.
2. The reviewer replies with a decision and the manifest hash.
3. `record` stores that decision verbatim. It approves the batch except for any photo
   rejected with a note.

`publish_global.py` gives a record `bundledImage`, and copies its thumbnail into
`Global/Images/`, only while a current approval covers that photo's fingerprint. An
unapproved photo never enters the pack, so it can't reach Release. The tool never
approves anything itself.

## Running it

The intake runs on the build Mac, where iNaturalist, FishBase and S3 are reachable. A
full uncached run is about 10,000 requests, roughly 3 hours at one per second. Reruns are
served from the cache. The outputs to commit are:
- `Data/SpeciesPhotos/PhotoManifest.json`;
- `Data/SpeciesPhotos/PermissionNeeded.csv`;
- `Reports/SpeciesPhotoCoverage.json`;
- `Data/SpeciesPhotos/Thumbnails/Thumbnails.json`, the thumbnail index.

Staging thumbnails (`Data/SpeciesPhotos/Thumbnails/*.jpg`) aren't committed: an approved
photo's committed copy is the one in `Global/Images/`. On a fresh checkout `publish_global.py`
keeps a pack image whose SHA-256 matches the index; to change photos, remake the thumbnails
first. A thumbnail run saves its index as it goes and lists any photo that failed to download.

## Size

`size_projection.py` measures the reviewed thumbnails and samples the source renditions
(HEAD requests only) to project the Global pack's photo size. The results and the
recommendation are in `Reports/SpeciesPhotoSizeProjection.json` and
[the plan](../../Docs/SpeciesPhotos.md).
