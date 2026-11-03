#!/usr/bin/env python3
"""Holdout mode: photos for evaluating photo identification, never for references or tuning.

  select    from the cached iNaturalist observation listings (the same responses the intake
            caches; no new requests), pick extra photos per Global species: up to 3 for the
            held-out set and up to 2 for the development split. Every photo comes from an
            observation and an observer different from the species' bundled reference photo,
            passes the intake's licence and quality filters, and was not rejected in photo
            review. Species without a reference photo are included, so "not covered" is
            measured too.
  nomatch   photos of subjects outside the catalogue (freshwater fish, corals, dolphins, seals,
            water birds), from the same licence-allowed source. A handful of requests.
  download  fetch every selected photo (iNaturalist's "medium" rendition) into
            Data/PhotoEvaluation/cache/ (git-ignored) and record its SHA-256 in the manifest.
  freeze    record the held-out manifest's SHA-256 in Data/PhotoEvaluation/Freeze.json. The
            evaluation refuses to run on a held-out manifest that doesn't match it.

Splits are by observer: an observer's photos go to one split only (a hash of the observer
ID), so no photographer, animal or dive is in both. Whether a photo is underwater is not in
iNaturalist's observation data, so `underwater` is recorded as null (unknown).
"""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import inat
import licences
import species_photos as sp
import thumbnails

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "Data/PhotoEvaluation"
CACHE = OUT / "cache"
MANIFESTS = {"holdout": OUT / "Holdout.v1.json", "development": OUT / "Development.v1.json"}
FREEZE = OUT / "Freeze.json"
LIMITS = {"holdout": 3, "development": 2}
SPLIT_SALT = "dive-id-photo-evaluation-v1"
UNDERWATER_UNKNOWN = "not in iNaturalist observation data"

# Outside the catalogue (fish, eels, crustaceans, molluscs, sharks, rays, sea cucumbers,
# seahorses, squid, octopus, turtles, urchins, worms, jellyfish, ...). Divers aren't
# observed on iNaturalist, so there is no diver set.
NO_MATCH_TAXA = {
    "Cichlidae": "freshwater fish", "Centrarchidae": "freshwater fish", "Cyprinidae": "freshwater fish",
    "Scleractinia": "coral reef without a catalogue animal", "Delphinidae": "dolphin", "Phocidae": "seal",
    "Anatidae": "water bird",
}
NO_MATCH_PER_TAXON = 6


def split_of(observer_id):
    """'development' for about a third of observers, 'holdout' for the rest; fixed per observer."""
    digest = hashlib.sha256(f"{SPLIT_SALT}:{observer_id}".encode()).digest()
    return "development" if digest[0] % 3 == 0 else "holdout"


def number(identifier):
    """'inaturalist:observation:123' -> 123."""
    tail = str(identifier or "").rpartition(":")[2]
    return int(tail) if tail.isdigit() else None


def references(records):
    """{speciesID: {"observations": {ids}, "photos": {ids}, "creators": {lowercased names}}}."""
    out = {}
    for record in records:
        image = record.get("bundledImage")
        if not image:
            continue
        entry = out.setdefault(record["id"].lower(), {"observations": set(), "photos": set(), "creators": set()})
        if number(image.get("observationID")) is not None:
            entry["observations"].add(number(image["observationID"]))
        if number(image.get("photoID")) is not None:
            entry["photos"].add(number(image["photoID"]))
        if image.get("creatorName"):
            entry["creators"].add(image["creatorName"].strip().lower())
    return out


def excluded_photos(path=sp.CHOICES):
    """Photo IDs rejected in photo review (possibly misidentified): never used."""
    _, excluded = sp.load_choices(path)
    return {number(p) for p in excluded}


def entry(row, observation, photo, name, split, covered, group):
    licence_name, licence_url = licences.display(photo["license_code"])
    user = observation.get("user") or {}
    return {
        "speciesID": row["speciesID"], "scientificName": row["scientificName"], "commonName": row["commonName"],
        "group": group, "covered": covered, "expected": "species", "split": split,
        "photoID": f"inaturalist:photo:{photo['id']}", "observationID": f"inaturalist:observation:{observation['id']}",
        "observerID": f"inaturalist:user:{user.get('id')}", "creatorName": name,
        "licenceCode": licences.normalise(photo["license_code"]), "licenseName": licence_name, "licenseURL": licence_url,
        "sourcePageURL": inat.PHOTO_PAGE.format(id=photo["id"]), "photoURL": sp.size_variant(photo["url"], "medium"),
        "observedOn": observation.get("observed_on"), "underwater": None, "underwaterSource": UNDERWATER_UNKNOWN,
    }


def select_species(row, observations, reference, policy, excluded, covered, group):
    """{split: [entries]} for one species, from its cached observation listing."""
    reference = reference or {"observations": set(), "photos": set(), "creators": set()}
    # The reference observer's iNaturalist user ID, when their observation is in the listing.
    reference_users = {(o.get("user") or {}).get("id") for o in observations if o.get("id") in reference["observations"]}
    picked = {"holdout": [], "development": []}
    seen_observers = set()
    for observation, photo, name, _, _ in sp.candidates(observations, policy):
        user = observation.get("user") or {}
        observer = user.get("id")
        names = {(user.get("login") or "").strip().lower(), (user.get("name") or "").strip().lower(), name.strip().lower()} - {""}
        if (observation["id"] in reference["observations"] or photo["id"] in reference["photos"] or photo["id"] in excluded
                or observer is None or observer in reference_users or names & reference["creators"] or observer in seen_observers):
            continue
        if photo is not observation["photos"][0]:
            continue  # one photo per observation: the first, as the observer chose
        split = split_of(observer)
        if len(picked[split]) == LIMITS[split]:
            continue
        seen_observers.add(observer)
        picked[split].append(entry(row, observation, photo, name, split, covered, group))
    return picked


def select(client, records, policy, excluded=frozenset()):
    """(manifests by split, counts). Uses cached responses only; species not yet fetched are counted."""
    refs = references(records)
    groups = {r["id"].lower(): (r.get("categories") or ["unknown"])[0] for r in records}
    picked = {"holdout": [], "development": []}
    counts = {"species": 0, "notYetFetched": 0, "unresolved": 0}
    for row in sp.species_from(records):
        counts["species"] += 1
        try:
            body, _ = client.taxa(row["scientificName"])
            match = sp.match_taxon(row["scientificName"], body.get("results", []))
            if match["status"] != sp.RESOLVED:
                counts["unresolved"] += 1
                continue
            listing, _ = client.observations(match["taxonID"], policy["allowedLicences"])
        except inat.Offline:
            counts["notYetFetched"] += 1
            continue
        chosen = select_species(row, listing.get("results", []), refs.get(row["speciesID"]), policy, excluded,
                                covered=row["speciesID"] in refs, group=groups[row["speciesID"]])
        for split in picked:
            picked[split] += chosen[split]
    check_independent(picked, refs)
    return picked, counts


def check_independent(picked, refs):
    """No held-out or development photo shares an observation or observer with a reference, and
    no observer appears in both splits."""
    observers = {split: {e["observerID"] for e in entries} for split, entries in picked.items()}
    assert not observers["holdout"] & observers["development"], "an observer is in both splits"
    for entries in picked.values():
        for e in entries:
            ref = refs.get(e["speciesID"], {"observations": set(), "creators": set()})
            assert number(e["observationID"]) not in ref["observations"], f"{e['photoID']} is from a reference observation"
            assert e["creatorName"].strip().lower() not in ref["creators"], f"{e['photoID']} is by the reference photographer"


def select_no_match(client, policy, taxa=NO_MATCH_TAXA, per_taxon=NO_MATCH_PER_TAXON):
    """{split: [entries]} for subjects outside the catalogue."""
    picked = {"holdout": [], "development": []}
    seen = set()
    for name, subject in sorted(taxa.items()):
        body, _ = client.taxon_by_name(name)
        exact = [t for t in body.get("results", []) if t.get("name", "").lower() == name.lower() and t.get("is_active", True)]
        if len(exact) != 1:
            continue
        listing, _ = client.observations(exact[0]["id"], policy["allowedLicences"])
        taken = 0
        for observation, photo, creator, _, _ in sp.candidates(listing.get("results", []), policy):
            observer = (observation.get("user") or {}).get("id")
            if observer is None or observer in seen or photo is not observation["photos"][0]:
                continue
            seen.add(observer)
            row = {"speciesID": None, "scientificName": name, "commonName": subject}
            item = entry(row, observation, photo, creator, split_of(observer), covered=False, group="noMatch")
            item["expected"] = "noMatch"
            picked[item["split"]].append(item)
            taken += 1
            if taken == per_taxon:
                break
    return picked


def manifest(split, entries):
    """Deterministic: fixed order, sorted keys, no timestamp."""
    ordered = sorted(entries, key=lambda e: (e["expected"], e["speciesID"] or "", e["scientificName"], e["photoID"]))
    return {"schemaVersion": 1, "split": split, "purpose": "evaluation only: never references, training or tuning"
            if split == "holdout" else "threshold tuning and development only", "photos": ordered}


def cache_name(photo):
    return f"inat-{number(photo['photoID'])}.jpg"


def download(photos, cache_dir, policy, fetch=thumbnails.download, sleep=time.sleep, failures=None):
    """Download each photo not already cached with a matching hash; set its sha256 and bytes."""
    cache_dir = Path(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)
    first = True
    for photo in photos:
        if licences.classify(photo["licenceCode"], policy) != licences.ALLOWED:
            raise ValueError(f"{photo['photoID']}: licence {photo['licenceCode']} is not allowed; not downloaded")
        path = cache_dir / cache_name(photo)
        if path.is_file() and photo.get("sha256") == hashlib.sha256(path.read_bytes()).hexdigest():
            continue
        if not first:
            sleep(1.0)
        first = False
        try:
            data = fetch(photo["photoURL"])
        except Exception as error:  # noqa: BLE001 - one failed photo must not stop a long run
            if failures is None:
                raise
            failures.append({"photoID": photo["photoID"], "error": f"{type(error).__name__}: {error}"})
            continue
        path.write_bytes(data)
        photo["sha256"], photo["bytes"] = hashlib.sha256(data).hexdigest(), len(data)
    return photos


def freeze(holdout_path=MANIFESTS["holdout"], freeze_path=FREEZE):
    """Record the held-out manifest's hash; refuses to re-freeze a different manifest."""
    digest = hashlib.sha256(Path(holdout_path).read_bytes()).hexdigest()
    if Path(freeze_path).exists():
        existing = json.loads(Path(freeze_path).read_text())
        if existing["holdoutManifestSHA256"] != digest:
            raise SystemExit("Freeze.json already records another held-out manifest. A new held-out set needs a new version and the owner's approval.")
        return existing
    photos = json.loads(Path(holdout_path).read_text())["photos"]
    if any("sha256" not in p for p in photos):
        raise SystemExit("download every held-out photo before freezing")
    frozen = {"schemaVersion": 1, "holdoutManifest": Path(holdout_path).name, "holdoutManifestSHA256": digest,
              "photos": len(photos), "rule": "Frozen before the first evaluation run. Never tune on it; thresholds come from the development split."}
    sp.write_json(freeze_path, frozen)
    return frozen


def merge(existing_path, picked):
    """Keep the hashes of photos already downloaded when re-selecting."""
    if not Path(existing_path).exists():
        return picked
    known = {p["photoID"]: p for p in json.loads(Path(existing_path).read_text())["photos"]}
    return [{**p, **{k: known[p["photoID"]][k] for k in ("sha256", "bytes") if k in known.get(p["photoID"], {})}} for p in picked]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("mode", choices=["select", "nomatch", "download", "freeze"])
    parser.add_argument("--interval", type=float, default=9.0, help="seconds between iNaturalist API requests (nomatch only)")
    args = parser.parse_args(argv)
    policy = licences.load_policy()
    log = lambda message: print(message, file=sys.stderr, flush=True)  # noqa: E731
    if args.mode == "freeze":
        print(json.dumps(freeze()))
        return 0
    if args.mode == "download":
        failures = []
        for split, path in MANIFESTS.items():
            document = json.loads(path.read_text())
            if split == "holdout" and FREEZE.exists():
                raise SystemExit("the held-out manifest is frozen; its photos are already downloaded")
            download(document["photos"], CACHE, policy, failures=failures)
            sp.write_json(path, document)
        print(json.dumps({"failed": failures}))
        return 0
    if FREEZE.exists():
        raise SystemExit("the held-out manifest is frozen; selecting again would change it")
    records = json.loads(sp.GLOBAL.read_text())
    client = inat.Client(sp.CACHE, offline=args.mode == "select", minimum_interval=args.interval, log=log)
    if args.mode == "select":
        picked, counts = select(client, records, policy, excluded_photos())
        existing = {split: [p for p in json.loads(path.read_text())["photos"] if p["expected"] == "noMatch"] if path.exists() else []
                    for split, path in MANIFESTS.items()}
    else:
        picked, counts = select_no_match(client, policy), {"requests": client.requests}
        existing = {split: [p for p in json.loads(path.read_text())["photos"] if p["expected"] != "noMatch"] if path.exists() else []
                    for split, path in MANIFESTS.items()}
    for split, path in MANIFESTS.items():
        sp.write_json(path, manifest(split, merge(path, picked[split] + existing[split])))
    print(json.dumps({**counts, **{split: len(picked[split]) for split in picked}}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
