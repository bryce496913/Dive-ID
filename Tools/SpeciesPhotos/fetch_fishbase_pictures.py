#!/usr/bin/env python3
"""Download the FishBase/SeaLifeBase v26.06 picture tables (photo metadata only, never photos).

Pinned like Tools/FishBaseIntake/release_manifest.json: each table by key, size and ETag
(its MD5). A download or cached file that does not match fails closed.
"""
import hashlib
import sys
import urllib.request
from pathlib import Path

SOURCE = "https://s3.us-west-2.amazonaws.com/us-west-2.opendata.source.coop/"
TABLES = {
    "fb-picturesmain.parquet": ("cboettig/fishbase/fb/v26.06/parquet/picturesmain.parquet", 2795743, "b7bc6bde6998b218eb4e4382797de7ff"),
    "slb-picturesmain.parquet": ("cboettig/fishbase/slb/v26.06/parquet/picturesmain.parquet", 450502, "d882d21aa6df00c785a3aca91d8e3bca"),
}
CACHE = Path(__file__).resolve().parents[2] / "Data/SpeciesPhotos/fishbase-cache"


def verified(path, size, md5):
    return path.is_file() and path.stat().st_size == size and hashlib.md5(path.read_bytes()).hexdigest() == md5


def fetch(cache=CACHE, opener=urllib.request.urlopen):
    cache.mkdir(parents=True, exist_ok=True)
    for name, (key, size, md5) in TABLES.items():
        path = cache / name
        if verified(path, size, md5):
            continue
        with opener(SOURCE + key, timeout=120) as response:
            data = response.read()
        if len(data) != size or hashlib.md5(data).hexdigest() != md5:
            raise SystemExit(f"{name}: download does not match the pinned size/ETag; not used")
        path.write_bytes(data)
    return cache


if __name__ == "__main__":
    print(fetch(Path(sys.argv[1]) if len(sys.argv) > 1 else CACHE))
