"""Stage per-species distribution (ocean basins, FAO areas, countries) from the pinned release.

The staged file follows the WoRMS response-cache rules (Tools/GlobalMarineImport/worms.py):
a schema-versioned snapshot naming its exact source (here, the pinned table keys and
ETags), when it was produced, its state and payload, and the payload's SHA-256. A
snapshot is checked on every read, and a schema, source or hash mismatch fails closed.
A valid snapshot for the same source is reused as is. Changing the source requires a
fresh output path; a snapshot is never edited in place. Writes are atomic.

Records whose status is questionable, misidentification, error, not established or
extirpated are kept with their status but never count towards ocean basins.
"""
import argparse
import csv
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
import fetch  # noqa: E402

SCHEMA_VERSION = 1
TABLES = ("faoareas", "faoarref", "country", "countref")
EXCLUDED_STATUSES = {"questionable", "misidentification", "error", "not established", "extirpated"}
OCEAN_BASINS = {18: "Arctic", 21: "Atlantic", 27: "Atlantic", 31: "Atlantic", 34: "Atlantic", 41: "Atlantic", 47: "Atlantic",
                37: "Mediterranean and Black Sea", 48: "Southern", 58: "Southern", 88: "Southern",
                51: "Indian", 57: "Indian", 61: "Pacific", 67: "Pacific", 71: "Pacific", 77: "Pacific", 81: "Pacific", 87: "Pacific"}
DEFAULT_OUTPUT = REPO / "Data/GlobalMarine/FishBase/Distribution.json"


class IntegrityError(RuntimeError):
    pass


def payload_hash(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def source_of(manifest):
    """The snapshot's address: every pinned table it is derived from."""
    return {f"{server}/{release['release']}/{table}": release["tables"][table]["etag"]
            for server, release in sorted(manifest["servers"].items()) for table in TABLES}


def read_snapshot(path, source):
    snapshot = json.loads(Path(path).read_text())
    if snapshot.get("schemaVersion") != SCHEMA_VERSION or snapshot.get("source") != source \
            or snapshot.get("state") != "success" or snapshot.get("payloadSHA256") != payload_hash(snapshot.get("payload")):
        raise IntegrityError(f"{path}: snapshot does not match its source or payload hash; use a fresh output path")
    return snapshot["payload"]


def write_snapshot(path, source, payload, now=None):
    path = Path(path)
    snapshot = {"schemaVersion": SCHEMA_VERSION, "source": source,
                "producedAt": (now or datetime.now(timezone.utc)).isoformat(), "state": "success",
                "payload": payload, "payloadSHA256": payload_hash(payload)}
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    temp.replace(path)


def included(status):
    return str(status or "").strip().lower() not in EXCLUDED_STATUSES


def _by_code(rows, key):
    grouped = {}
    for r in rows:
        grouped.setdefault(r[key], set()).add(str(r.get("Status") or "").strip().lower())
    return [{"code": code, "status": "/".join(sorted(statuses)), "counts": any(included(s) for s in statuses)}
            for code, statuses in sorted(grouped.items())]


def distribution_for(fao_rows, country_rows):
    """One species' FAO-area and country rows -> its staged distribution. Names live in
    the payload's shared lookups so each species stores only codes and statuses."""
    areas, countries = _by_code(fao_rows, "AreaCode"), _by_code(country_rows, "C_Code")
    basins = sorted({OCEAN_BASINS[a["code"]] for a in areas if a["counts"] and a["code"] in OCEAN_BASINS})
    known = any(a["counts"] for a in areas) or any(c["counts"] for c in countries)
    return {"oceanBasins": basins, "faoAreas": areas, "countries": countries, "distributionKnown": known}


def stage(manifest, cache, offline, keys):
    read = lambda sv, t, cols: fetch.read_table(manifest, cache, sv, t, cols, offline)
    payload = {"species": {}, "faoAreaNames": {}, "countries": {}}
    for server in sorted(manifest["servers"]):
        codes = {code for sv, code in keys if sv == server}
        fao_names = {r["AreaCode"]: r["FAO"] for r in read(server, "faoarref", ["AreaCode", "FAO"])}
        countries = {r["C_Code"]: r for r in read(server, "countref", ["C_Code", "PAESE", "ISO3Alpha"])}
        fao, country = {}, {}
        for r in read(server, "faoareas", ["SpecCode", "AreaCode", "Status"]):
            if r["SpecCode"] in codes:
                fao.setdefault(r["SpecCode"], []).append(r)
        for r in read(server, "country", ["SpecCode", "C_Code", "Status"]):
            if r["SpecCode"] in codes:
                country.setdefault(r["SpecCode"], []).append(r)
        for code in sorted(codes):
            entry = distribution_for(fao.get(code, []), country.get(code, []))
            payload["species"][f"{server}:{code}"] = entry
            for a in entry["faoAreas"]:
                payload["faoAreaNames"][str(a["code"])] = fao_names.get(a["code"], "")
            for c in entry["countries"]:
                ref = countries.get(c["code"]) or {}
                payload["countries"][c["code"]] = {"name": ref.get("PAESE") or "", "iso3": ref.get("ISO3Alpha") or ""}
    return payload


def resolved_keys(resolution_csv):
    with open(resolution_csv, newline="") as f:
        return {(r["server"], int(r["specCode"])) for r in csv.DictReader(f) if r["specCode"]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", default=fetch.DEFAULT_CACHE)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--output", default=DEFAULT_OUTPUT)
    args = parser.parse_args(argv)
    manifest = fetch.load_manifest()
    source = source_of(manifest)
    output = Path(args.output)
    if output.exists():
        payload = read_snapshot(output, source)  # fails closed on any mismatch
        print(f"reused verified snapshot {output} ({len(payload['species'])} species)")
        return 0
    payload = stage(manifest, args.cache, args.offline, resolved_keys(output.parent / "NameResolution.csv"))
    write_snapshot(output, source, payload)
    known = sum(v["distributionKnown"] for v in payload["species"].values())
    print(f"staged {len(payload['species'])} species ({known} with a known distribution) -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
