"""Download and verify the pinned FishBase/SeaLifeBase Parquet tables.

Every table is pinned in release_manifest.json by S3 key, ETag and size. The
ETag of these single-part uploads is the file's MD5, so a cached file is used
only when its size and MD5 match the pin. A mismatch fails closed; nothing is
silently re-downloaded over a pinned file.
"""
import argparse
import hashlib
import json
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "release_manifest.json"
DEFAULT_CACHE = HERE.parents[1] / "Data/GlobalMarine/FishBase/cache"


class PinMismatch(RuntimeError):
    pass


def load_manifest(path=MANIFEST):
    return json.loads(Path(path).read_text())


def cached_path(cache_dir, server, table):
    return Path(cache_dir) / server / f"{table}.parquet"


def verify(path, pin):
    data = Path(path).read_bytes()
    if len(data) != pin["size"]:
        raise PinMismatch(f"{path}: size {len(data)} != pinned {pin['size']}")
    digest = hashlib.md5(data).hexdigest()
    if digest != pin["etag"]:
        raise PinMismatch(f"{path}: md5 {digest} != pinned {pin['etag']}")


def fetch(manifest, cache_dir, server, table, offline=False, opener=urllib.request.urlopen):
    pin = manifest["servers"][server]["tables"][table]
    path = cached_path(cache_dir, server, table)
    if path.exists():
        verify(path, pin)
        return path
    if offline:
        raise FileNotFoundError(f"{path} is not cached and --offline was given")
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(".partial")
    with opener(f"{manifest['source']}/{pin['key']}", timeout=120) as response:
        partial.write_bytes(response.read())
    try:
        verify(partial, pin)
    except PinMismatch:
        partial.unlink()
        raise
    partial.replace(path)
    return path


def read_table(manifest, cache_dir, server, table, columns, offline=False):
    """Return the table's rows as dicts. pyarrow is only needed here."""
    import pyarrow.parquet as pq
    path = fetch(manifest, cache_dir, server, table, offline=offline)
    return pq.read_table(path, columns=columns).to_pylist()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", default=DEFAULT_CACHE)
    parser.add_argument("--offline", action="store_true", help="verify the cache only; never download")
    args = parser.parse_args(argv)
    manifest = load_manifest()
    for server, release in manifest["servers"].items():
        for table in sorted(release["tables"]):
            path = fetch(manifest, args.cache, server, table, offline=args.offline)
            print(f"ok {server}/{release['release']}/{table} -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
