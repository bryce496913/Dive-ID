#!/usr/bin/env python3
"""Make bundle-ready thumbnails (400 px longest side by default) for selected species.

Reads Data/SpeciesPhotos/PhotoManifest.json, downloads each chosen photo's `photoURL`
(iNaturalist's "large" rendition, about 1,024 px) with the intake's User-Agent and one
request per second, and writes a JPEG to Data/SpeciesPhotos/Thumbnails/ plus
Thumbnails.json (photoID -> file, SHA-256, size, dimensions). Only photos whose licence
the policy allows are ever downloaded; FishBase/SeaLifeBase photos never are.

A thumbnail is staging data: it reaches the app only when the photo is approved in photo
review and publish_global.py copies it into the Global pack.
"""
import argparse
import hashlib
import io
import json
import sys
import time
import urllib.request
from pathlib import Path

import inat
import licences

REPO = Path(__file__).resolve().parents[2]
MANIFEST = REPO / "Data/SpeciesPhotos/PhotoManifest.json"
THUMBNAILS = REPO / "Data/SpeciesPhotos/Thumbnails"
INDEX = "Thumbnails.json"


def file_name(photo):
    """Stable, filesystem-safe and unique per photo: <speciesID>-inat-<photo number>.jpg."""
    source, _, number = photo["photoID"].rpartition(":")
    if source != "inaturalist:photo" or not number.isdigit():
        raise ValueError(f"not an iNaturalist photo: {photo['photoID']}")
    return f"{photo['speciesID'].lower()}-inat-{number}.jpg"


def thumbnail(data, longest_side, quality=82):
    """JPEG bytes and (width, height), resized so the longest side is at most longest_side."""
    from PIL import Image  # Pillow; only needed when making thumbnails
    with Image.open(io.BytesIO(data)) as image:
        image = image.convert("RGB")
        image.thumbnail((longest_side, longest_side), Image.LANCZOS)
        out = io.BytesIO()
        image.save(out, "JPEG", quality=quality, optimize=True, progressive=False)
        return out.getvalue(), image.size


def download(url, opener=urllib.request.urlopen):
    request = urllib.request.Request(url, headers={"User-Agent": inat.USER_AGENT})
    with opener(request, timeout=60) as response:
        return response.read()


def make(photos, out_dir, policy, fetch=download, sleep=time.sleep, resize=thumbnail, failures=None, save_every=50):
    """Write a thumbnail for each photo not already indexed; return the updated index. A photo
    that fails to download or decode is listed in failures (when given) and skipped; the index
    is saved every save_every thumbnails, so a long run that stops keeps what it made."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    index_path = out_dir / INDEX
    index = json.loads(index_path.read_text()) if index_path.exists() else {}
    first = True
    for photo in sorted(photos, key=lambda p: p["photoID"]):
        if licences.classify(photo["licenceCode"], policy) != licences.ALLOWED:
            raise ValueError(f"{photo['photoID']}: licence {photo['licenceCode']} is not allowed; not downloaded")
        name = file_name(photo)
        entry = index.get(photo["photoID"])
        if entry and (out_dir / name).is_file() and hashlib.sha256((out_dir / name).read_bytes()).hexdigest() == entry["sha256"]:
            continue
        if not first:
            sleep(1.0)
        first = False
        try:
            data, (width, height) = resize(fetch(photo["photoURL"]), policy["thumbnailLongestSidePixels"])
        except Exception as error:  # noqa: BLE001 - one bad file must not stop a long run
            if failures is None:
                raise
            failures.append({"photoID": photo["photoID"], "error": f"{type(error).__name__}: {error}"})
            continue
        (out_dir / name).write_bytes(data)
        index[photo["photoID"]] = {"fileName": name, "speciesID": photo["speciesID"], "sha256": hashlib.sha256(data).hexdigest(),
                                   "bytes": len(data), "width": width, "height": height}
        if len(index) % save_every == 0:
            index_path.write_text(json.dumps(index, indent=1, sort_keys=True) + "\n")
    index_path.write_text(json.dumps(index, indent=1, sort_keys=True) + "\n")
    return index


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--species", nargs="+", help="species IDs to make thumbnails for")
    parser.add_argument("--all", action="store_true", help="every species in the manifest")
    parser.add_argument("--first-only", action="store_true", help="only each species' first-ranked photo (the one the app shows)")
    parser.add_argument("--manifest", default=MANIFEST)
    parser.add_argument("--output", default=THUMBNAILS)
    parser.add_argument("--policy", default=licences.POLICY_PATH)
    args = parser.parse_args(argv)
    policy = licences.load_policy(args.policy)
    if not args.all and not args.species:
        parser.error("name --species or pass --all")
    photos = json.loads(Path(args.manifest).read_text())["photos"]
    wanted = {p["speciesID"].upper() for p in photos} if args.all else {s.upper() for s in args.species}
    photos = [p for p in photos if p["speciesID"].upper() in wanted and (p["rank"] == 1 or not args.first_only)]
    missing = wanted - {p["speciesID"].upper() for p in photos}
    if missing:
        print(f"no selected photo for: {', '.join(sorted(missing))}", file=sys.stderr)
    failures = []
    index = make(photos, args.output, policy, failures=failures)
    print(json.dumps({"thumbnails": len(index), "bytes": sum(e["bytes"] for e in index.values()), "failed": failures}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
