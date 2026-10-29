# Photo identification: plan

**Scope:** a diver submits a photo of a creature in the app (today from the photo
library; later the camera), and the app suggests which species it is, on the device and
offline. The bundled species photos are only the reference material it matches against.

Drafted 2026-10-28. **A plan only: no code has changed.** Photo identification stays
off (`FeatureAvailability.photoIdentificationEnabled = false`) until the gates below
pass. Accuracy, size and latency figures here are planning estimates, labelled as such;
none has been measured for this app.

## Where things stand

- **Preparation only.** `PhotoIdentificationView` picks a library photo.
  `DefaultPhotoProcessingService` re-encodes it as JPEG: at most 2,048 px for identification
  and 1,200 px for the preview, quality 0.8. Re-encoding drops EXIF, including location and
  camera data. The photo lives only in the in-memory search session.
  `LocalMarineLifeIdentificationService` rejects `.processedPhoto` requests
  (`unsupportedSource`), and "Take Photo" is a disabled placeholder.
- **Reference photos.** 1,934 of 4,798 Global species have one approved, bundled
  thumbnail (400 px, about 26 KB). **2,864 have none.** By group, that's 2,368 fish, 229
  eels, 93 crustaceans, 45 molluscs, 39 sharks, 28 rays, 20 seahorses and 15 sea
  cucumbers. The iNaturalist re-fetch now running covers the 2,393 species not yet
  fetched. At the rate seen so far (80% of fetched species had an allowed photo), roughly
  1,000 species should still have no photo afterwards. That's an extrapolation, not a
  count.
- **Licences.** `Tools/SpeciesPhotos/photo_policy.json` allows CC0, CC BY and CC BY-NC.
  ND, all-rights-reserved and unknown licences are excluded; SA is held for your decision.
  FishBase/SeaLifeBase photos are never used without written permission. The current
  policy covers **bundling and displaying** photos, not training models on them (see
  [Training and reference data](#2-training-and-reference-data)).
- **Text-encoder groundwork.** Text semantic search has a working Core ML conversion,
  parity and packaging pipeline (`Docs/RealEncoderLocalValidation-2026-10-25.md`). The
  September readiness report (`Docs/RealEncoderProductionReadiness.md`) froze the
  method: archived manifests, parity tolerances set before the holdout, a one-shot
  holdout, and device budgets. The same discipline applies to images.
- **Evaluation protocol.** `IndependentProtocol.v1.json` defines rank bounds (positive
  top-3, ambiguous top-10), a 0.64 cap for ambiguous and limited cases, minimum rates
  (top-1 0.40, top-3 0.60, top-10 0.80, no-match 1.0) and minimum samples (30
  positives, 10 per policy class). It also requires curator labels from independent
  evidence. In-app feedback already records "I have a photo I can send".

## 1. Approach options

| | A. Classifier (Core ML) | B. Image embeddings + nearest neighbour | C. Hybrid through the existing ranker |
|---|---|---|---|
| What it is | Fixed set of species classes. Trained on licensed images, e.g. Create ML transfer learning on Apple's built-in feature extractor, or a fine-tuned network. | An image encoder turns the diver's photo and each reference photo into vectors; the nearest species win. Adding a species means adding vectors, not retraining. | B (or A) proposes image candidates. When the diver also types a description, the existing BM25 + `LocalSpeciesRanker` combines both, with the region as a prior. |
| Accuracy (estimate) | Good for species with many varied training photos. Poor for the long tail. Can't express "none of these" without a separate check. | Depends on the encoder. Apple's general-purpose feature print is weak for telling similar fish apart. Biology-trained encoders (e.g. BioCLIP-style CLIP models trained on iNaturalist and similar data) are much stronger. Works from a few references per species. | The best expected accuracy. A description resolves look-alikes a photo can't ("seen at night", "about 2 m"), and a photo resolves what a short description can't. Abstains more sensibly. |
| Model size (estimate) | Create ML on Apple's built-in extractor: under 5 MB (the extractor ships with iOS). A bundled fine-tuned network: 20–100 MB. | Apple feature print: 0 MB. Biology encoder image tower: ~80–90 MB at 16-bit, ~25–45 MB at 8-bit. Reference vectors: 512 dims × 2 bytes = 1 KB per photo, so 5–50 MB for 1–10 photos per species across Global. | Same as B, plus nothing new on the description side. |
| On-device latency (estimate, not measured) | ~10–50 ms per photo on a recent iPhone's Neural Engine. | Encoding ~20–80 ms. A brute-force search over 50,000 vectors is a few ms on the CPU. | B plus the existing description search (~1 s cold, tens of ms warm today). |
| Species with no photo | **Can't predict them at all.** They're outside the class set. | **Can't match them by image**, unless the encoder also has a text side (CLIP-style). Then a "zero-shot" text prompt from the scientific and common name stands in for a missing reference. Expect it to be much weaker than a real reference photo. | They still come through the description path. The image side contributes nothing for them and must never push them down just for lacking a photo, the same "never exclude on uncertainty" rule as search. |
| Main risk | Long-tail coverage; retraining for every catalogue change. | Encoder licence and size; surface photos of the wrong individual or life stage. | More moving parts. Combining scores needs care so one side doesn't silently overrule the other. |

**Recommendation: B first, measured against a free baseline, then C.** Classifier A is
dropped unless B underperforms on the common species.
- A classifier can't cover the long tail, and the catalogue changes with every approved
  batch.
- Embeddings fit the catalogue as it is: each approved reference photo is one more
  vector.
- The hybrid matches how divers actually use the app: a photo plus a few words.

The free baseline is Apple's built-in Vision feature print against the 1,934 bundled
thumbnails. It ships no model and has no licence question, and it tells us cheaply
whether a stronger encoder is worth its size.

## 2. Training and reference data

### Sources and what their licences allow

| Source | Display and bundle (current policy) | Use as reference vectors (kNN) | Train or fine-tune a model |
|---|---|---|---|
| iNaturalist, CC0 | Yes | Yes | Yes |
| iNaturalist, CC BY | Yes, with attribution | Yes; keep attribution with each vector's source | Likely yes. Whether trained weights are an "adaptation" is legally unsettled; record attribution for every training image. |
| iNaturalist, CC BY-NC | Yes, while Dive ID stays non-commercial | Yes, non-commercial only | Same as CC BY, **plus** the non-commercial condition binds every use of the model. A paid app, ads or a commercial spin-off would end it. |
| CC BY-SA / BY-NC-SA | Held for your decision | Same | If weights count as an adaptation, share-alike may require releasing them under the same licence. Avoid for training. |
| CC BY-ND | Excluded (thumbnails resize) | Excluded | Excluded. Fine-tuning arguably adapts the work. |
| FishBase / SeaLifeBase photos | Only with written permission | Only with written permission | Only with written permission that names model training |
| Pre-trained encoder weights (e.g. BioCLIP) | n/a | The model's own licence (BioCLIP's code and weights are MIT) | Its **training data** has mixed licences. Using published weights is an ordinary licence question for your review; it doesn't turn their training images into ours. |
| Divers' own photos (pilot, TestFlight) | Never bundled | **Never**: they're the evaluation set | **Never** without a separate, explicit training consent. Evaluation consent doesn't cover it. |

Model training needs a policy decision of its own (see [Decisions](#decisions-needed)).
The display and bundle policy doesn't cover it.

### How many images per species

- **Embedding kNN (option B):** 3–10 reference photos per species. Use different
  photographers, angles and life stages, and include at least one from underwater.
  That's ~5–50 MB of vectors for Global.
- **Classifier (option A):** realistically 50–100+ varied images per class before
  accuracy holds up. Few long-tail marine species have that many permissively licensed
  research-grade photos.
- **Collection cost.** The intake is limited to about 10,000 iNaturalist API requests a
  day. Photo *files* come from the open-data host, which isn't throttled the same way,
  and the observation listings already cached hold up to 30 observations per species.
  Raising `maximumPhotosPerSpecies` from 2 to 10 for **reference** use (not bundling)
  costs mostly downloads, not API calls. A GBIF download of iNaturalist research-grade
  occurrences with media is the bulk alternative. It needs a GBIF account (yours).
- **Review.** Every reference photo needs the same human approval as a bundled photo.
  The rejected larval lionfish and surface-splash eagle ray show why: a bad reference
  teaches the system the wrong animal. At 10 photos per species, that's ~48,000 photos to
  review across Global. That's far beyond on-device review, so it needs a sampling plan
  (see Decisions).

### Underwater problems

- **Colour cast.** Red is lost within a few metres, and photos turn blue or green. The
  same fish looks different at 3 m and 25 m, and with or without a strobe. Mitigations:
  - include deep, no-strobe references;
  - test with and without automatic white balance at query time;
  - never treat colour as decisive on its own (the description ranker already gives
    colour cautious weight).
- **Turbidity and backscatter:** low contrast, a soft subject, particles. Detect very
  low image quality and abstain, rather than guess.
- **Juveniles versus adults.** Many reef fish change completely (Queen Angelfish, French
  Angelfish, parrotfish phases). The catalogue already has `appearanceVariants` with life
  stages. References should carry a life-stage tag, and a juvenile match should say so,
  as description results do with `matchedLifeStage`.
- **Partial views and crowds:** a tail, a head in a hole, several species in one frame.
  The first version asks for "one animal, mostly in frame". A later crop or "tap the
  animal" step can isolate it.
- **Surface and out-of-water photos** (catches, boat shots) differ from what divers see.
  Keep them out of references; the reviewer flags them, as on the photo review page.

## 3. Evaluation

### Held-out set, never used for training or references

- **Primary set:** pilot photo submissions. A diver's photo arrives separately ("I have a
  photo I can send"), and a curator who hasn't seen engine output labels it from
  independent evidence. These photos are also the curator's evidence for the description
  pilot. That's fine for labelling, but they **must never** enter references, training or
  thresholds.
- **Leakage rules:**
  - split by observer and encounter, not by photo;
  - exclude every photo by a holdout photographer, and every photo from a holdout
    observation, from references and training;
  - de-duplicate near-identical frames;
  - freeze a manifest and hashes before running anything, as the description protocol
    does.
- **Size.** The 12-account description pilot can't reach the protocol's minimum of 30
  positives and 10 per policy class. A photo holdout needs its own collection, of at
  least ~40 positives plus no-match and ambiguous cases. Until then, results are
  descriptive only, exactly as in the pilot.
- **Development set:** iNaturalist research-grade photos from observers not used in
  references, split by observer. These are for tuning and thresholds only, never
  reported as independent evidence.

### Metrics, matching the description gates

- **Top-1, top-3 and top-10.** Positives must reach rank 3 or better, and ambiguous cases
  rank 10 or better (`positiveRankBound` 3, `ambiguousRankBound` 10). Floors are top-1
  0.40, top-3 0.60 and top-10 0.80 (`minimumRates`). Report numerators and denominators,
  never 0/0.
- **Abstention.**
  - Below a confidence threshold set on development data only, show "no confident
    match", not a list.
  - Report how often it abstains, and its accuracy when it doesn't.
  - Treat low quality (blur, turbidity) as abstain, not failure.
- **No-match class.** Include photos of animals outside the catalogue, and non-animal or
  out-of-domain photos (wreck, diver, sand). Correct no-match must be 1.0, as for
  descriptions, and a no-match photo must never surface a confident species.
- **Confidence.** Scores are relative strengths, not probabilities. Cap them at 0.64 for
  ambiguous or limited cases, the same rule as descriptions.
- **Coverage.** Report results separately for species with a reference photo, species
  without one (expected weak; must not be hidden), and Release versus development
  access.
- **Device budgets, set before measuring** (adapted from the encoder readiness
  proposals), on the oldest supported iPhone and one current one, offline:
  - cold model load ≤ 2 s;
  - photo to results ≤ 1 s;
  - warm p95 ≤ 500 ms;
  - peak extra memory ≤ 200 MiB;
  - packaged image assets within the size you approve.

## 4. Product rules

- **Results are suggestions.** Photo results use the same match-strength wording and
  "possible matches are suggestions, not confirmed identifications" disclaimer as
  description results. Nothing is auto-confirmed. "Save Identification" still records a
  match, and "Was this right?" still applies.
- **Photos stay on the device.** There's no upload, cloud inference or network call. The
  processed photo stays in the session, and EXIF (location, camera) is already stripped.
  A photo is kept only if the diver saves the identification, and then on the device.
- **No silent training.** Divers' photos never feed references, training or thresholds.
  Any future "help improve Dive ID with your photo" needs its own opt-in consent,
  separate from evaluation and quoting consents, and its own review.
- **Never exclude on uncertainty.** Species without a reference photo aren't penalised
  for that. With a description, they compete on the description. Photo-only results say
  that some species can't be matched from photos yet.
- **The camera comes later.** "Take Photo" needs a camera usage string and its own
  review; the first version uses the photo library only.
- **Gated release.** The feature stays behind `FeatureAvailability` and Internal builds
  until the holdout gates pass, and then goes to TestFlight before Release.

## 5. Phases, effort and what each needs from you

Effort is for one developer working with Claude, in calendar weeks. These are estimates.

| Phase | Work | Effort | Needs from you |
|---|---|---|---|
| 0. Decisions | Settle the decisions below; write the training/reference licence policy beside `photo_policy.json` | days | The decisions below |
| 1. Free baseline | Apple Vision feature print + kNN over the 1,934 bundled thumbnails, Internal build only. Development set from held-back iNaturalist observers. Report top-k and abstention. | ~1 week | Nothing new; review the report |
| 2. Reference set | Extend the intake to keep up to N reference photos per species (not bundled), with life-stage and underwater tags. Sampled review plan. Finish the iNaturalist re-fetch. | 2–3 weeks + review time | Licence decision; review sample; optionally a GBIF account |
| 3. Biology encoder | Choose and freeze an encoder; convert to Core ML with the existing pipeline; check parity; build the reference index; zero-shot text vectors for species with no photo; measure size and latency | 2–4 weeks | Model licence review; app-size budget |
| 4. Hybrid | Feed image candidates into `LocalSpeciesRanker` alongside description evidence; abstain rules; UI for photo + optional description; same disclaimers | 2–3 weeks | Review of wording and screens |
| 5. Photo holdout | Collect and curate a photo holdout; freeze manifest and thresholds; run once; device budgets on two iPhones | 4–8 weeks, mostly collection | Divers' photos and consents; a curator; two devices |
| 6. TestFlight, then Release | Internal → TestFlight external testers → Release only if gates pass | 1–2 weeks + Beta App Review | Go/no-go after the holdout |

**Total:** roughly 3–5 months to a holdout-verified decision. Phases 1 and 2 can overlap,
and phase 5's collection can start as soon as the photo intake path is agreed.

## Decisions needed

1. **Training versus references.** May permissively licensed photos (CC0, CC BY,
   CC BY-NC) be used as **reference vectors**? May they be used to **train or fine-tune**
   a model? My recommendation: references yes, training not yet.
2. **Share-alike.** Keep CC BY-SA and BY-NC-SA out of references and training, or decide
   now?
3. **Commercial status.** Confirm that Dive ID stays non-commercial (no paid app, ads or
   in-app purchases) for as long as CC BY-NC material is used. If not, the reference set
   shrinks to CC0 and CC BY.
4. **Encoder.** Approve trying a published biology encoder (e.g. a BioCLIP-style model,
   MIT-licensed weights) after a licence review, or stay with Apple's built-in feature
   print only.
5. **App size budget** for photo identification (model plus reference vectors). For
   example ≤ 100 MB, or a separate on-device download pack (still offline once
   installed).
6. **Reference photos per species, and how they're reviewed.** For example up to 10 per
   species for references only, with review by sampling (say 1 in 10 plus every
   juvenile-tagged photo), or full review of a smaller set.
7. **Photo holdout collection.** May the TestFlight invitation also ask for a photo (sent
   separately, never through the app)? Who curates the labels?
8. **First release scope.** Photo-only, or photo plus an optional description (the
   hybrid) from the start? I recommend the hybrid, with photo-only results labelled as
   weaker.
9. **Camera.** Library-only first, or include "Take Photo" in the first version?
