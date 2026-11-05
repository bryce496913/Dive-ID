# Photo model candidates

An evaluation of image models against Apple's built-in matcher (Vision feature print)
for photo identification. **Nothing here ships:** no candidate model or index goes into
any build, and Release has photo identification off. Started 2026-10-29.

## Shortlist

| | BioCLIP | DINOv2-small | Vision feature print (baseline) |
|---|---|---|---|
| Kind | Biology-trained CLIP (ViT-B/16), image and text | General-purpose self-supervised vision model (ViT-S/14), image only | Apple's built-in, image only |
| Source | `imageomics/bioclip` (Hugging Face), via OpenCLIP | `facebook/dinov2-small` (Hugging Face) | Part of iOS |
| Code licence | MIT (OpenCLIP: MIT) | Apache-2.0 | Apple SDK |
| Weights licence | MIT | Apache-2.0 | Part of iOS: nothing to bundle |
| Training data | TreeOfLife-10M: iNaturalist (iNat21), BIOSCAN-1M and Encyclopedia of Life images. The compilation is CC0; each image keeps its own licence, many CC BY-NC or CC BY-SA. | LVD-142M, a curated web image set; not released, licences unknown | Not disclosed |
| Download | 599 MB (`open_clip_pytorch_model.bin`, a PyTorch pickle, loaded weights-only) | 88 MB (`model.safetensors`) | 0 |
| Image tower in the app (estimate) | ~86 M parameters: ~172 MB float16, ~86 MB 8-bit | ~22 M parameters: ~44 MB float16, ~22 MB 8-bit | 0 |
| Embedding | 512 floats | 384 floats | 768 floats |
| Text zero-shot by species name | **Yes**: a species-name text vector can stand in for a missing reference photo, which could cover the ~2,860 species without one. Text vectors are computed on the Mac and bundled; the text model doesn't ship. | No | No |

**Training data implications.** Using published weights is a question of the weights'
own licence (MIT and Apache-2.0 here), not of each training image's licence. Whether
weights trained on CC BY-NC and CC BY-SA images inherit those terms is legally
unsettled. BioCLIP's training set contains such images, as does a lot of Dive ID's own
photo set. The app is non-commercial, which reduces the risk; a lawyer should confirm
before anything ships.

## Considered and left out

| Model | Why not |
|---|---|
| BioCLIP 2 (`imageomics/bioclip-2`, MIT) | ViT-L/14, 1.71 GB of weights: roughly 600 MB in the app even at float16, and too large for this Mac's free disk (5.6 GB). Worth trying only if BioCLIP shows a clear gain. |
| MobileCLIP-S2 (`apple/MobileCLIP-S2-OpenCLIP`) | Small and fast, but its Apple ML Research licence allows research use only, not a product distributed to the public. |
| OpenAI CLIP ViT-B/16 (MIT) | Offered as an optional third, not chosen (owner, 2026-10-29). |

## Method

- Convert each image tower to Core ML on the Mac with pinned versions
  (`Tools/PhotoModels`), and check parity against the original PyTorch model on fixture
  images.
- Build each reference index from the same 1,934 approved bundled photos with the
  Prompt 2 tool pattern. BioCLIP also gets a text-vector variant for the species without
  a photo.
- Run the frozen held-out evaluation (`Docs/PhotoEvaluation.md`) for each candidate and
  the baseline. Each candidate's abstain threshold comes from the development split
  only.
- Measure app size added, load time, memory and per-query latency in the simulator.

## Results so far (2026-10-29)

### Conversion and parity

Converted with `Tools/PhotoModels/convert.py` (torch 2.5.0, coremltools 8.3.0, OpenCLIP
2.29.0, transformers 4.46.3; `requirements.txt`). Parity is the cosine between the
PyTorch embedding and the Core ML embedding on 8 bundled photos.

| | Parameters | float16 | 8-bit weights | Parity, float16 | Parity, 8-bit |
|---|---:|---:|---:|---:|---:|
| BioCLIP image tower | 86.2 M | 172.6 MB | 86.7 MB | 0.99968 | 0.99904 |
| DINOv2-small | 22.1 M | 43.4 MB | 22.0 MB | 0.99974 | 0.99809 |

DINOv2 resizes its position embeddings on every call with an operation Core ML can't
convert. The input is always 224 × 224, so the resized embeddings are computed once
during conversion.

### Reference indexes

Built from the 1,934 approved bundled photos with the photo index tool's builder (same
licence and missing-photo checks), on the Mac:

| Index | Entries | Size | Build time |
|---|---:|---:|---:|
| BioCLIP, photos | 1,934 × 512 | 4.1 MB | 30 s |
| BioCLIP, photos + species-name text | 4,798 (2,864 by name) | 10.1 MB | – |
| DINOv2, photos | 1,934 × 384 | 3.1 MB | 14 s |
| Vision feature print (baseline) | 1,934 × 768 | 6.1 MB | 15 s |

### Speed, memory and parity on each platform

Ten bundled photos per model. A query is the embedding plus a brute-force search. The
simulator ran a Debug test build on the CPU, so its search part is unoptimized.

| | Host load | Host query (median) | Simulator load | Simulator query (median) | Simulator parity with the Mac index | Own species first |
|---|---:|---:|---:|---:|---:|---:|
| BioCLIP | 14.9 s (first load: Core ML prepares the model for this Mac) | 19.4 ms | 2.1 s | 655 ms | 0.9997 | 10/10 |
| DINOv2 | 0.08 s | 8.7 ms | 0.7 s | 289 ms | 0.9996 | 10/10 |
| Vision (baseline) | 0.001 s (decode) | ~9 ms | 0.2 s | ~250 ms | **0.18** (the phone: 0.94–0.99) | 0/12 in the simulator |

Memory: the measured footprint change on load was within ±5 MiB on both platforms
(Core ML maps the weights from disk). BioCLIP's host load showed +192 MiB while preparing
the model.

Unlike the built-in feature print, both Core ML models compute nearly identical
embeddings in the simulator and on the Mac.

### On the iPhone 14 Pro (2026-10-29)

Debug test build, default compute units (Neural Engine). The models are copied into the
test bundle from the git-ignored `DiveIDTests/CandidateModels/`; they never enter the app.
A query is the embedding plus a brute-force search, and the search is unoptimized in a
Debug build: the built-in matcher's search alone took 121 ms there.

| | Model | First load | Query (median / max) | Parity with the Mac index | Own species first |
|---|---:|---:|---:|---:|---:|
| BioCLIP | 172.6 MB | 8.1 s | 99.5 / 122.9 ms | **0.99999** | 10/10 |
| DINOv2-small | 43.4 MB | 4.3 s | 66.6 / 71.4 ms | **0.99986** | 10/10 |
| Vision (baseline) | 0 | 0.16 s | 132 ms (10.9 ms print + 121 ms search) | 0.94–0.99 | 12/12 |

- **First load:** Core ML prepares the model for the Neural Engine the first time it
  loads on a device. Later loads are usually much faster; that wasn't measured.
- **Memory:** the footprint change on load was 0–1 MiB. Core ML maps the weights from
  disk.
- **Parity:** a Mac-built index works on the phone for both candidates, which isn't true
  of the built-in feature print. The tolerance lowered for Vision (0.9) wouldn't be
  needed for them.

### Development split (17 no-match photos only)

The share of non-catalogue photos that abstain at each threshold (higher is better):

| Threshold | Vision | BioCLIP | BioCLIP + text | DINOv2 |
|---:|---:|---:|---:|---:|
| 0.80 | 0.00 | 0.47 | 0.47 | 0.53 |
| 0.85 | 0.35 | 0.82 | 0.82 | 0.82 |
| 0.90 | 0.76 | 1.00 | 1.00 | 0.94 |
| Threshold for all 17 to abstain | 0.93 | 0.87 | 0.87 | 0.91 |

BioCLIP separates non-catalogue subjects from its references at a lower threshold than
the built-in matcher, which leaves more room for real matches. This says nothing about
accuracy yet: there are no species photos in the development split.

## Status

The accuracy comparison waits for the frozen held-out set. The iNaturalist download
hasn't fetched the photo listings it is selected from. When it has:

1. `holdout.py select` → `download` → `freeze`.
2. Run the development split for each candidate and set each threshold by the protocol
   rule.
3. Run the frozen held-out evaluation for the baseline, BioCLIP (photos, then photos +
   text) and DINOv2.

```sh
DIVEID_PHOTO_CANDIDATES=<candidates> DIVEID_PHOTO_EVAL_CANDIDATE=bioclip \
  DIVEID_PHOTO_EVAL_REPORT=Reports/PhotoEvaluation-bioclip.json \
  swift test -c release --filter PhotoEvaluationTests/testPhotoEvaluation
```

Nothing is recommended until those results exist. The selection report, with the exact
candidates, pinned revisions, proposed selection rules and remaining steps, is
[PhotoModelSelection.md](PhotoModelSelection.md).
