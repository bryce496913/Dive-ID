# Dive ID

Dive ID helps divers and instructors identify marine life from imperfect post-dive descriptions, especially after dives where internet access may be unavailable, unreliable, expensive, or inappropriate.

## Offline-first design

Dive ID is currently an offline-first native iOS prototype:

- Description processing runs on the device.
- The species catalogue is bundled with the app.
- No account is required.
- No backend is required.
- No internet connection is required for description identification.
- Descriptions are not uploaded.
- Selected photos remain on the device.
- Saved identifications remain local and persistent.

## Current identification method

Version 0.1 uses an explainable local matcher rather than a trained AI model. The app extracts local clues from the description, compares them with structured bundled species profiles, applies deterministic weighted ranking, and returns up to 10 likely matches when there is meaningful evidence. Explanations are generated from matched and conflicting catalogue traits.

Match strength reflects relative similarity to the clues in the description. It is not scientific certainty and should not be treated as a confirmed identification.

## Current catalogue limitation

The initial bundled catalogue intentionally contains a small set of species so the offline feature flow can be validated before expanding coverage. Results are limited to species included with this version of Dive ID.

## On-device AI roadmap

Future work may evaluate Apple Natural Language, `NLEmbedding`, Create ML, Core ML, Vision, bundled text-ranking models, and bundled photo-classification models. Future models should remain usable offline and fit behind the existing parser/ranker and identification-service boundaries.

## Development

Open `DiveID.xcodeproj` in Xcode 16 or newer. Build the `DiveID` scheme. Run `DiveIDTests` locally. Run `DiveIDUITests` locally when needed.

Automated GitHub Actions checks are intentionally not configured during the current step-by-step prototype phase. Build and test verification is performed locally in Xcode.

## Recommended next feature

Expand and validate the offline species catalogue and description-ranking quality with a repeatable set of diver descriptions. Measure whether the intended species appears in the top 10 and top 3, whether explanations are useful, which vocabulary is missing, and which species are commonly confused.
