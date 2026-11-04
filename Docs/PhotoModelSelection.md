# Photo model selection: Vision, BioCLIP, DINOv2

**Status (2026-11-04): selection deferred.** No candidate can be selected yet. There are
no species photos in either evaluation split, so accuracy, coverage and per-group results
haven't been measured for any candidate. Nothing here changes the app: photo
identification stays off in Release, the built-in Vision matcher stays the Debug and
Internal recognizer, and no candidate model or index is in any build. No photo is ever
sent to a network service.

Background: [PhotoModelCandidates.md](PhotoModelCandidates.md) (shortlist, conversion,
first measurements) and [PhotoEvaluation.md](PhotoEvaluation.md) (data, gates, runner).

## 1. The candidates, as complete recognizers

None of these models names a species by itself. Each one turns a photo into a vector,
and the species comes from a **reference gallery**: the 1,934 approved catalogue photos
bundled with Global (`Images/`, one per covered species, licence-checked). All three
use the same mapping, so only the embedding differs:

1. Embed the photo and L2-normalise the vector.
2. For every species, take the cosine to its best reference vector (brute force).
3. Rank species by that cosine. The score is `(cosine + 1) / 2`, a similarity, **not a
   probability**.
4. Below the abstain threshold, show "No confident photo match". The threshold is set
   per candidate on the development split only (Section 3). Above it, results are
   capped at "Possible match" (score ≤ 0.64), as the app already does.

| | Vision (baseline) | BioCLIP | DINOv2-small |
|---|---|---|---|
| Model | `VNGenerateImageFeaturePrintRequest` revision 2, CPU | OpenCLIP ViT-B/16 image tower, `imageomics/bioclip` at `ce901ab3c6a913f9e9ef94ce6d27761069f4f01c` | `facebook/dinov2-small` at `ed25f3a31f01632728cabb09d1542f84ab7b0056` |
| Licence | Part of iOS | MIT (code: OpenCLIP, MIT) | Apache-2.0 |
| Input | Vision's own scaling | 224 × 224 centre crop (Vision scaling), CLIP mean and std inside the model | 224 × 224 centre crop, ImageNet mean and std inside the model; position embeddings resized once at conversion |
| Output | 768 floats | 512 floats | 384 floats (pooled CLS) |
| In the app | Nothing (iOS) | Core ML float16, 172.6 MB (8-bit: 86.7 MB) | Core ML float16, 43.4 MB (8-bit: 22.0 MB) |
| Gallery | `PhotoIndex.bin`, 6.1 MB | 4.1 MB index | 3.1 MB index |
| Variant | – | **photos + text**: the 2,864 species without a reference photo get a text vector from BioCLIP's text tower ("a photo of {class order family genus species} with common name {name}."). 10.1 MB. Only the vectors ship, not the text model. | – |

The model revisions are pinned in `Tools/PhotoModels/convert.py` (`PINS`). It now records
each weight file's SHA-256 in `parity.json`. The October conversion predates the pins:
DINOv2's repository hasn't changed since 2023, so it used this revision. BioCLIP's last
changed in February 2026, so it almost certainly did too, but that wasn't recorded.

## 2. Data

| Role | Source | Now |
|---|---|---|
| Reference gallery | 1,934 approved bundled photos (owner-reviewed batches, `PhotoChoices.json`) | Ready |
| Calibration | `Data/PhotoEvaluation/Development.v1.json` (`e0493e13…`) | 17 no-match photos; **0 species photos** |
| Held-out | `Data/PhotoEvaluation/Holdout.v1.json` (`f46aa7af…`), frozen in `Freeze.json` before the first run | 25 no-match photos; **0 species photos**; not frozen |

Rules, enforced by `Tools/SpeciesPhotos/holdout.py`:
- **Independent of the references:** never the same observation, photo, observer or
  creator as a species' reference photo.
- **No leakage between splits:** split by observer (a salted hash), so no observer is in
  both splits. One photo per observation.
- **Same licence policy as the references:** permitted for evaluation, with attribution
  kept.
- **Identity:** the research-grade iNaturalist identification (community-agreed),
  established before and independent of any candidate.
- **Underwater:** recorded as unknown, since iNaturalist doesn't say.

What the evaluation covers:

| Category | How |
|---|---|
| Covered species | Species with a reference photo: up to 3 held-out and 2 development photos each |
| Unsupported catalogue species | Species without a reference photo, included and reported apart |
| Lookalikes | A wrong top-1 that the expected species' record lists as a similar species is counted as a lookalike confusion |
| Marine but not in the catalogue | Dolphins, seals, bare reef; penguins added 2026-11-04 |
| Not marine | Freshwater fish, water birds; land animals and land birds added 2026-11-04 |
| Unusable | `DIVEID_PHOTO_EVAL_UNUSABLE=1`: every fourth species photo of the same split, heavily blurred and nearly black, plus blank water. Derived, labelled "derived", and kept out of the gates. |

Divers' own photos would be the best held-out set (`IndependentDiverCollection.md`,
`suppliedPhotoFile`); none have been received.

## 3. Acceptance criteria

**Approved (2026-10-29, `PhotoProtocol.v1.json`, `7ca0c257…`), held-out, at each
candidate's calibrated threshold:** covered top-1 ≥ 0.40, top-3 ≥ 0.60, top-10 ≥ 0.80;
no-match correctly rejected = 1.00; confidence compliant = 1.00. At least 30 covered and
10 no-match photos, or the gate fails as not evaluated.

**Threshold rule (approved):** the smallest threshold at which every development
no-match photo is rejected. A held-out run takes it only from a development report for
the same recognizer, version and colour setting (`DIVEID_PHOTO_EVAL_CALIBRATION`); the
runner refuses anything else.

**Reported for every candidate, not gated:**
- coverage at the threshold;
- selective top-1 (right among the photos answered);
- false acceptance of no-match photos;
- rejection of unusable photos;
- uncovered species answered;
- lookalike confusions;
- per animal group;
- a calibration table: top-1 rate within each band of similarity;
- model and gallery size, first and warm load, query median and maximum, and peak memory
  on the same iPhone.

**Proposed selection rules (not approved; for the owner to decide before the held-out
run):**
1. Only a candidate that passes every approved gate can be selected. If none passes,
   selection stays deferred and Vision remains the Debug and Internal recognizer.
2. On the iPhone 14 Pro: a warm query median of 300 ms or less, a warm load of 1 s or
   less, and a peak footprint under 300 MiB.
3. Among the candidates that pass, prefer higher covered top-1 at equal no-match
   rejection. Prefer the smaller download when top-1 differs by less than 0.03.
4. BioCLIP's "photos + text" variant counts only if it doesn't lower the covered results.
   Its uncovered results are reported, not credited.

## 4. Measurements so far

The October figures are from [PhotoModelCandidates.md](PhotoModelCandidates.md). Debug
builds, 10 bundled photos each; these check speed and parity, not accuracy.

| | Vision | BioCLIP | DINOv2-small |
|---|---:|---:|---:|
| Parity with the reference implementation | Phone vs Mac prints: 0.94–0.99 | Core ML vs PyTorch 0.99968; phone vs Mac 0.99999 | 0.99974; phone vs Mac 0.99986 |
| iPhone 14 Pro first load | 0.16 s | 8.1 s | 4.3 s |
| iPhone 14 Pro query (median / max) | 132 ms (121 ms of it the Debug search) | 99.5 / 122.9 ms | 66.6 / 71.4 ms |
| Footprint change on load | – | 0–1 MiB (weights memory-mapped) | 0–1 MiB |
| Development: threshold rejecting all 17 no-match photos | 0.93 | 0.87 | 0.91 |

Re-run on 2026-11-04, Vision on the development split, with blank water: 18 photos.
Chosen threshold 0.93, at which all 17 no-match photos and the blank frame are rejected.
Calibration table (top-1 right per band): 0.80–0.85: 0 of 7, 0.85–0.90: 0 of 7,
0.90–0.95: 0 of 4. There are no species photos, so nothing can be right yet.

**Not measured:**
- top-1 and top-3, coverage, per-group results, lookalikes, and false acceptance at a
  calibrated threshold, for any candidate;
- warm load and peak memory on the phone;
- the "photos + text" variant on the phone.

## 5. Missing evidence and how to finish

| Missing | Why | Next step |
|---|---|---|
| Species photos in both splits | `holdout.py select` uses the cached iNaturalist observation listings. The photo intake is fetching them (restarted 2026-11-04, about 11 hours to finish). Selecting from a partial cache would favour the species fetched first. | When the intake finishes: run `holdout.py select`, then `nomatch` (it picks up the new subjects), then `download`. |
| Converted candidate models | The October artifacts were deleted with an old scratch folder | Re-download at the pinned revisions (BioCLIP 599 MB, DINOv2 88 MB, plus the pinned PyTorch toolchain) and convert. Needs the owner's OK to download. |
| Approval of the proposed selection rules | They are new | The owner approves or changes them before the held-out run |
| Warm load and peak memory on the phone | Newly added to the measurement | `testMeasureCandidates` on the iPhone, with the models in `DiveIDTests/CandidateModels/` (git-ignored) |
| Divers' photos | None received | Optional; held out the same way |

Commands, in order:

```sh
# 1. Models (Mac, after approval), at the pinned revisions:
hf download imageomics/bioclip --revision ce901ab3c6a913f9e9ef94ce6d27761069f4f01c --local-dir <downloads>/bioclip
hf download facebook/dinov2-small --revision ed25f3a31f01632728cabb09d1542f84ab7b0056 --local-dir <downloads>/dinov2-small
python -I Tools/PhotoModels/convert.py --models <downloads> --out <candidates>
DIVEID_PHOTO_CANDIDATES=<candidates> swift test --filter PhotoModelCandidateTests/testBuildCandidateIndexes

# 2. Data (after the intake finishes):
python3 Tools/SpeciesPhotos/holdout.py select
python3 Tools/SpeciesPhotos/holdout.py nomatch
python3 Tools/SpeciesPhotos/holdout.py download

# 3. Calibrate each candidate on the development split (repeat for bioclip, dinov2, and
#    bioclip with DIVEID_PHOTO_EVAL_VARIANT=photos+text; omit the candidate for Vision):
DIVEID_PHOTO_CANDIDATES=<candidates> DIVEID_PHOTO_EVAL_CANDIDATE=bioclip DIVEID_PHOTO_EVAL_SPLIT=development \
  DIVEID_PHOTO_EVAL_UNUSABLE=1 DIVEID_PHOTO_EVAL_REPORT=Reports/PhotoEvaluationDevelopment-bioclip.json \
  swift test -c release --filter PhotoEvaluationTests/testPhotoEvaluation

# 4. Freeze once, then one held-out run per candidate at its calibrated threshold:
python3 Tools/SpeciesPhotos/holdout.py freeze
DIVEID_PHOTO_CANDIDATES=<candidates> DIVEID_PHOTO_EVAL_CANDIDATE=bioclip DIVEID_PHOTO_EVAL_UNUSABLE=1 \
  DIVEID_PHOTO_EVAL_CALIBRATION=Reports/PhotoEvaluationDevelopment-bioclip.json \
  DIVEID_PHOTO_EVAL_REPORT=Reports/PhotoEvaluation-bioclip.json \
  swift test -c release --filter PhotoEvaluationTests/testPhotoEvaluation

# 5. Device: copy the compiled models and indexes into DiveIDTests/CandidateModels/, then
xcodebuild test -project DiveID.xcodeproj -scheme DiveID -destination 'id=<iPhone>' \
  -only-testing:DiveIDTests/PhotoModelCandidateTests/testMeasureCandidates
```

The held-out results come from the Mac. The candidates' Core ML embeddings match the
phone's to 0.9999, so their phone accuracy should be the same; Vision's prints differ
slightly on the phone (0.94–0.99).

**Checksums:**
- `Holdout.v1.json` `f46aa7af…0432`
- `Development.v1.json` `e0493e13…2cc5`
- `PhotoIndex.bin` `e4270165…411c`
- `PhotoProtocol.v1.json` `7ca0c257…63d1`
- `Tools/PhotoModels/requirements.txt` `72ec04b9…29c4`
- The converted models' checksums go in each `parity.json`.

## 6. Recommendation

**Defer selection.** The device and parity results so far favour the Core ML candidates
over Vision on two counts:
- Their embeddings match between Mac and phone, so one Mac-built index works on every
  device.
- They reject the development no-match photos at lower thresholds (BioCLIP 0.87,
  DINOv2 0.91, Vision 0.93), which may leave more room for real matches.

That says nothing about identification accuracy, which hasn't been measured. The next
implementation step is evidence, not integration:
1. Approve the model downloads and the proposed selection rules.
2. Let the intake finish, then select, download and freeze the species photos.
3. Run steps 3–5 above for all three candidates.

Production integration is a separate decision after those results are reviewed.

## Limits

- **Small gallery:** one reference photo per covered species, and 2,864 species have
  none. Every candidate's results are limited by this as well as by its model.
- **Licences:** BioCLIP's training images include CC BY-NC and CC BY-SA photos. Whether
  that affects the weights is unsettled; a lawyer should confirm before anything ships.
- **Identity labels:** research-grade iNaturalist identifications are community labels,
  not expert verification.
- **Debug timings:** the October phone figures came from Debug builds, so the search part
  is slower than a Release build would be.
