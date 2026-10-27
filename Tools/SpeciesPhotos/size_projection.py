#!/usr/bin/env python3
"""Project the app-size cost of species photos for the whole Global pack.

Measures the thumbnails made so far (Data/SpeciesPhotos/Thumbnails/Thumbnails.json) and,
for the same photos, the byte size of iNaturalist's "large" (about 1,024 px) and
"original" (up to 2,048 px) renditions with HEAD requests only. It scales the averages to
every species the coverage report gives an allowed iNaturalist photo. It writes
Reports/SpeciesPhotoSizeProjection.json.
"""
import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

import inat

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "Data/SpeciesPhotos/PhotoManifest.json"
THUMBNAILS = REPO / "Data/SpeciesPhotos/Thumbnails/Thumbnails.json"
COVERAGE = REPO / "Reports/SpeciesPhotoCoverage.json"
REPORT = REPO / "Reports/SpeciesPhotoSizeProjection.json"
MB = 1_000_000


def content_length(url, opener=urllib.request.urlopen):
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": inat.USER_AGENT})
    with opener(request, timeout=60) as response:
        return int(response.headers["Content-Length"])


def mean(values):
    return sum(values) / len(values) if values else 0


def project(sample, species_with_photo):
    """sample: [{"thumbnail": bytes, "large": bytes, "original": bytes}]. Megabytes for one
    and for two photos per species, per rendition."""
    out = {}
    for rendition in ("thumbnail", "large", "original"):
        average = mean([s[rendition] for s in sample])
        out[rendition] = {"averageBytes": round(average), "onePerSpeciesMB": round(average * species_with_photo / MB, 1),
                          "twoPerSpeciesMB": round(2 * average * species_with_photo / MB, 1)}
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", default=REPORT)
    args = parser.parse_args(argv)
    photos = {p["photoID"]: p for p in json.loads(MANIFEST.read_text())["photos"]}
    index = json.loads(THUMBNAILS.read_text())
    coverage = json.loads(COVERAGE.read_text())
    sample = []
    for photo_id, entry in sorted(index.items()):
        large = photos[photo_id]["photoURL"]
        sizes = {"thumbnail": entry["bytes"], "large": content_length(large)}
        time.sleep(1.0)
        sizes["original"] = content_length(large.replace("/large.", "/original."))
        time.sleep(1.0)
        sample.append(sizes)
    species = coverage["withINaturalistPhoto"]
    report = {"sampledPhotos": len(sample), "speciesWithAllowedPhoto": species, "globalSpecies": coverage["species"],
              "thumbnailLongestSidePixels": max(max(e["width"], e["height"]) for e in index.values()),
              "projection": project(sample, species),
              "note": "Sizes are JPEG bytes. iNaturalist 'large' is about 1,024 px and 'original' up to 2,048 px on the longest side."}
    Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["projection"], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
