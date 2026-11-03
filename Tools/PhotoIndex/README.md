# Photo index

Builds the reference index photo identification searches: an Apple Vision feature print
(`VNGenerateImageFeaturePrintRequest`, revision 2) of every approved photo bundled in the
Global pack. It runs on a Mac, never on the phone.

```sh
swift run -c release photo-index
```

It writes `DiveID/Resources/IdentificationPacks/Global/PhotoIndex.bin` (bundled with the
app) and `Data/PhotoIndex/Global.json` (SHA-256s of the species file, every photo and the
index; not bundled). It fails if an approved photo is missing or its licence isn't in
`Tools/SpeciesPhotos/photo_policy.json`'s allowed list. Rerun it whenever Global's species
file or photos change: `Tools/CI/test_photo_index.py` fails CI while the index is stale.

## On the phone

The app loads the index the first time photo identification is used and rejects it, with
"Photo matching is unavailable", when its request revision or catalogue content version
doesn't match the app, or when a reference photo's print computed on the phone differs
from the index by more than the parity tolerance.

## Parity (2026-10-29)

Twelve bundled photos, printed where the test ran and compared with the Mac-built index
(`PhotoIndexTests.testFeaturePrintsHereMatchTheIndex`):

| Where | Minimum cosine | Median cosine | Own species first |
|---|---:|---:|---:|
| Mac (host) | 0.99999994 | 1.0 | 12/12 |
| iPhone 14 Pro (Vision's default device) | 0.937 | 0.992 | 12/12 |
| iOS simulator (CPU) | 0.179 | 0.286 | 0/12 |

The phone can't run the request on the CPU (espresso error −2), and building the index on
the Mac's CPU or its default device gave the same phone figures. The owner lowered the
tolerance from 0.995 to a 0.9 minimum and 0.98 median, with every photo's own species
first. The simulator's prints are unrelated and it is refused. The alternative, building
the index on the phone at first launch, was not chosen.
