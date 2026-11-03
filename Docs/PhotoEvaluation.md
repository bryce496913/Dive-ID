# Photo identification evaluation

Measures photo identification on photos it has never seen, before it is tuned or shipped.
Photo identification stays off in Release whatever the results.

**Status (2026-10-29): built; species photos not selected yet.** The held-out and
development species photos come from the iNaturalist observation listings the photo
intake caches. The running intake has fetched species lookups only (3,326 of 4,798), not
listings, so `holdout.py select` has nothing to pick from yet. Selection, the freeze and
the first held-out run follow when it has. The no-match photos are selected and
downloaded (25 held-out, 17 development).

## Data

| Set | File | Use |
|---|---|---|
| Held-out | `Data/PhotoEvaluation/Holdout.v1.json` | Gates only. Its hash is frozen in `Freeze.json` before the first run; the runner refuses a manifest that doesn't match. Never tuned on. |
| Development | `Data/PhotoEvaluation/Development.v1.json` | Setting the abstain threshold and any other tuning. |
| Real divers (later) | private holdout, from the curator worksheet's `suppliedPhotoFile` | Photos divers send separately; held out the same way. |

Selection rules are in [Tools/SpeciesPhotos/README.md](../Tools/SpeciesPhotos/README.md#holdout-mode-photo-evaluation):
- **Independent of the references:** a different observation and observer from the
  species' bundled photo, enforced by an assertion.
- **Split by observer:** no observer in both splits.
- **Same rules as references:** same licence policy and quality filters.
- **Uncovered species included:** species without a reference photo are in the set.
- **Underwater unknown:** recorded as unknown, since iNaturalist doesn't say.

The photos are kept outside git in `Data/PhotoEvaluation/cache/`. At about 260 KB each
(the no-match sample), a full selection could reach 1–2 GB.

## Running

```sh
DIVEID_PHOTO_EVAL_SPLIT=development DIVEID_PHOTO_EVAL_REPORT=Reports/PhotoEvaluationDevelopment.json \
  swift test -c release --filter PhotoEvaluationTests/testPhotoEvaluation
DIVEID_PHOTO_EVAL_REPORT=Reports/PhotoEvaluation.json \
  swift test -c release --filter PhotoEvaluationTests/testPhotoEvaluation
```

Each photo goes through the real service path (Global, Release catalogue access, the
bundled Vision index) on the Mac. The report gives top-1, top-3, top-10, abstain rate and
confidence compliance for:
- species with a reference photo (covered) and without one (uncovered);
- each animal group;
- underwater, not underwater and unknown;
- no-match photos.

The development run adds the threshold sweep. The phone's feature prints differ slightly
from the Mac's (median cosine 0.992), so phone results may differ a little.

## Gates (approved 2026-10-29)

From `Data/Evaluation/PhotoProtocol.v1.json`, written and approved by the owner as proposed
before any held-out run. The floors mirror the description gates (`V05Protocol.v2.json`):

| Gate | Floor | On |
|---|---:|---|
| coveredTop1 | 0.40 | held-out photos of species with a reference photo; abstaining is a miss |
| coveredTop3 | 0.60 | same |
| coveredTop10 | 0.80 | same |
| noMatchCorrect | 1.00 | held-out no-match photos; correct means "No confident photo match" |
| confidenceCompliant | 1.00 | every result; nothing above 0.64 ("Possible match") |

A gate with fewer than 30 covered or 10 no-match cases fails as not evaluated. A failing
gate fails the test. Uncovered species, animal groups and underwater are reported, not
gated. Floors are not changed after seeing held-out results without the owner's approval.

## Abstain threshold

Set from the development split only. The rule: the smallest normalized similarity at
which the development no-match photos meet `noMatchCorrect`. The development report shows
accuracy against abstain rate for every threshold from 0.50 to 0.99. The Vision
recognizer's threshold is still the provisional 0.5 (cosine 0), which no feature print
falls below, so it never abstains.

**Early development signal** (no-match photos only; no covered development photos yet):
at 0.5, all 17 development no-match photos got species results. The share that abstain
rises to 0.35 at 0.85 and 0.76 at 0.90, and reaches 1.0 at 0.93 (cosine 0.86). What that
costs real matches is unknown until the covered development photos are in.

## Experiment: underwater colour correction (2026-10-29)

A Debug and Internal toggle on the photo screen ("Experimental: underwater colour
correction") applies a grey-world white balance before recognition. It scales each colour
channel so the photo's average is neutral, with gains capped at 3×, which restores some
of the red that water absorbs. It is off by default. The evaluation applies the same
correction with `DIVEID_PHOTO_EVAL_COLOUR=1`.

Development split, which so far holds only the 17 no-match photos:

| Threshold | No-match correct, plain | No-match correct, colour corrected |
|---:|---:|---:|
| 0.85 | 0.35 | 0.29 |
| 0.90 | 0.76 | 0.59 |
| 0.92 | 0.94 | 0.82 |
| 0.93 | 1.00 | 1.00 |

Correction made non-catalogue photos look slightly more like the reference photos, so
fewer of them abstain at the same threshold. Its effect on real matches can't be measured
until the development split has species photos. It stays off. Rerun both before deciding
again.
