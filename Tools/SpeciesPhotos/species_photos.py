#!/usr/bin/env python3
"""Species photo intake for the Global pack: resolve -> select -> manifest.

  resolve   match each Global species to one iNaturalist taxon by scientific name
            (synonyms, ambiguous and unmatched names are flagged, never guessed)
  select    pick at most N allowed-licence, research-grade photos per resolved taxon; a photo
            the reviewer chose (Data/SpeciesPhotos/PhotoChoices.json) comes first, and one they
            excluded is never picked again
  manifest  write the deterministic photo manifest, the coverage report and the
            FishBase/SeaLifeBase "permission needed" list

Nothing here approves a photo or changes the app's packs. Photos are reviewed in batches
(Tools/CatalogReview/photo_batches.py) and only approved ones reach Release.
"""
import argparse
import csv
import io
import json
import sys
from pathlib import Path

import inat
import licences

ROOT = Path(__file__).resolve().parents[2]
GLOBAL = ROOT / "DiveID/Resources/IdentificationPacks/Global/Creatures.json"
OUT = ROOT / "Data/SpeciesPhotos"
CACHE = OUT / "cache"
REPORT = ROOT / "Reports/SpeciesPhotoCoverage.json"
CHOICES = OUT / "PhotoChoices.json"

RESOLVED, SYNONYM, AMBIGUOUS, UNMATCHED = "resolved", "synonym", "ambiguous", "unmatched"


def species(path=GLOBAL):
    records = json.loads(Path(path).read_text())
    rows = []
    for r in records:
        codes = [d.get("stableSourceID", "") for d in r.get("dataSources", [])]
        code = next((c for c in codes if c.startswith(("FishBase:SpecCode:", "SeaLifeBase:SpecCode:"))), None)
        rows.append({"speciesID": r["id"].lower(), "commonName": r["commonName"], "scientificName": r["scientificName"],
                     "sourceCode": code})
    return sorted(rows, key=lambda x: x["speciesID"])


# --- resolve ---------------------------------------------------------------------------

def match_taxon(scientific_name, results):
    """One active species taxon whose name equals the record's, or a flagged outcome."""
    target = " ".join(scientific_name.split()).lower()
    species_results = [t for t in results if t.get("rank") == "species"]
    exact = [t for t in species_results if t.get("name", "").lower() == target and t.get("is_active", True)]
    if len(exact) == 1:
        return {"status": RESOLVED, "taxonID": exact[0]["id"], "taxonName": exact[0]["name"]}
    if len(exact) > 1:
        return {"status": AMBIGUOUS, "candidates": sorted(t["id"] for t in exact)}
    # Matched through another name: the record's name is a synonym in iNaturalist.
    via = [t for t in species_results if (t.get("matched_term") or "").lower() == target]
    if len(via) == 1:
        return {"status": SYNONYM, "candidates": [via[0]["id"]], "taxonName": via[0]["name"]}
    if len(via) > 1:
        return {"status": AMBIGUOUS, "candidates": sorted(t["id"] for t in via)}
    return {"status": UNMATCHED}


def resolve(client, rows):
    out = []
    for row in rows:
        body, fetched = client.taxa(row["scientificName"])
        match = match_taxon(row["scientificName"], body.get("results", []))
        out.append({**row, **match, "resolvedOn": fetched})
    return out


# --- select ----------------------------------------------------------------------------

def size_variant(url, variant):
    """iNaturalist photo URLs name their size ('square'); the same photo at another size."""
    for name in ("square", "small", "medium", "large", "original"):
        marker = "/" + name + "."
        if marker in url:
            return url.replace(marker, "/" + variant + ".")
    return url


def creator(observation, photo):
    user = observation.get("user") or {}
    name = (user.get("name") or "").strip() or (user.get("login") or "").strip()
    if not name:
        # "(c) Jane Diver, some rights reserved (CC BY-NC)"
        attribution = photo.get("attribution") or ""
        name = attribution.removeprefix("(c)").split(",")[0].strip()
    return name


def candidates(observations, policy):
    """Allowed photos, best first: wild, research grade, large enough, landscape preferred."""
    found = []
    for position, observation in enumerate(observations):
        if observation.get("quality_grade") != "research" or observation.get("captive"):
            continue
        for index, photo in enumerate(observation.get("photos", [])):
            if photo.get("hidden") or photo.get("flags"):
                continue
            if licences.classify(photo.get("license_code"), policy) != licences.ALLOWED:
                continue
            size = photo.get("original_dimensions") or {}
            width, height = size.get("width") or 0, size.get("height") or 0
            if max(width, height) < policy["minimumLongestSidePixels"]:
                continue
            name = creator(observation, photo)
            if not name:
                continue
            landscape = width >= height * 1.1
            # Rank: landscape (a proxy for a lateral, whole-animal view), the observation's
            # vote order, then the observation's first photo; ties broken by photo ID.
            found.append(((0 if landscape else 1, position, index, photo["id"]), observation, photo, name, width, height))
    return [item[1:] for item in sorted(found, key=lambda item: item[0])]


def load_choices(path=CHOICES):
    """({speciesID: [chosen photo IDs]}, {excluded photo IDs}). A choice still has to pass every
    filter; it only moves to the front. Excluding a photo is how a rejection sticks across runs."""
    path = Path(path)
    if not path.exists():
        return {}, set()
    document = json.loads(path.read_text())
    chosen = {}
    for entry in document.get("chosen", []):
        chosen.setdefault(entry["speciesID"].lower(), []).append(entry["photoID"])
    return chosen, {entry["photoID"] for entry in document.get("excluded", [])}


def select(client, resolved, policy, choices=({}, set())):
    chosen_ids, excluded = choices
    out = []
    for row in resolved:
        if row["status"] != RESOLVED:
            out.append({**row, "photos": []})
            continue
        body, fetched = client.observations(row["taxonID"], policy["allowedLicences"])
        chosen, observers = [], set()
        preferred = chosen_ids.get(row["speciesID"].lower(), [])
        ranked = [c for c in candidates(body.get("results", []), policy) if f"inaturalist:photo:{c[1]['id']}" not in excluded]
        ranked.sort(key=lambda c: preferred.index(f"inaturalist:photo:{c[1]['id']}") if f"inaturalist:photo:{c[1]['id']}" in preferred
                    else len(preferred))
        for observation, photo, name, width, height in ranked:
            observer = (observation.get("user") or {}).get("id")
            if observer in observers:
                continue  # at most one photo per observer, for variety
            observers.add(observer)
            licence_name, licence_url = licences.display(photo["license_code"])
            chosen.append({
                "photoID": f"inaturalist:photo:{photo['id']}",
                "observationID": f"inaturalist:observation:{observation['id']}",
                "creatorName": name,
                "licenceCode": licences.normalise(photo["license_code"]),
                "licenseName": licence_name, "licenseURL": licence_url,
                "sourceName": "iNaturalist",
                "sourcePageURL": inat.PHOTO_PAGE.format(id=photo["id"]),
                "observationURL": inat.OBSERVATION_PAGE.format(id=observation["id"]),
                "photoURL": size_variant(photo["url"], "large"),
                "originalWidth": width, "originalHeight": height,
                "observedOn": observation.get("observed_on"),
                "retrievedOn": fetched,
            })
            if len(chosen) == policy["maximumPhotosPerSpecies"]:
                break
        later = None
        if not chosen and policy["laterDecisionLicences"]:
            # Is a share-alike photo all there is? Recorded for the owner's later decision.
            held, _ = client.observations(row["taxonID"], policy["laterDecisionLicences"], per_page=1)
            later = held.get("total_results", 0)
        out.append({**row, "photos": chosen, "laterDecisionPhotoObservations": later})
    return out


# --- FishBase / SeaLifeBase fallback ----------------------------------------------------

FISHBASE_PAGE = {"FishBase": "https://www.fishbase.se/photos/PicturesSummary.php?ID={code}&what=species",
                 "SeaLifeBase": "https://www.sealifebase.se/photos/PicturesSummary.php?ID={code}&what=species"}
FISHBASE_IMAGE = {"FishBase": "https://www.fishbase.se/images/species/{name}",
                  "SeaLifeBase": "https://www.sealifebase.se/images/species/{name}"}


def fishbase_fallback(rows_without_photo, pictures):
    """FishBase/SeaLifeBase photos are copyrighted by their photographers; the data
    licence does not cover them. None is downloaded. Each species gets one row: the
    preferred picture's photographer and page, for the owner to seek permission (or to
    confirm a picture FishBase marks public domain)."""
    by_code, by_name = {}, {}
    for p in pictures:
        by_code.setdefault((p["database"], p["SpecCode"]), []).append(p)
        by_name.setdefault(f"{p['PicGenus']} {p['PicSpecies']}".lower(), []).append(p)
    out = []
    for row in rows_without_photo:
        found = []
        if row.get("sourceCode"):
            database, _, code = row["sourceCode"].split(":")
            found = by_code.get((database, int(code)), [])
        if not found:
            found = by_name.get(row["scientificName"].lower(), [])
        found = [p for p in found if "drawing" not in (p.get("PictureType") or "") and p.get("PictureType") != "stamp"]
        if not found:
            continue
        best = sorted(found, key=lambda p: (not p.get("PicPreferred"), "underwater" not in (p.get("PictureType") or ""),
                                            not p.get("BestPic"), p["autoctr"]))[0]
        database = best["database"]
        statement = (best.get("Copyright") or "").strip() or "not stated"
        out.append({
            "speciesID": row["speciesID"], "scientificName": row["scientificName"], "commonName": row["commonName"],
            "database": database, "photographer": (best.get("AuthName") or "").strip() or "not stated",
            "photoPageURL": FISHBASE_PAGE[database].format(code=best["SpecCode"]),
            "photoURL": FISHBASE_IMAGE[database].format(name=best["PicName"]),
            "copyrightStatement": statement,
            # Public domain is not one of the allowed licences: the owner confirms it.
            "action": "confirm public domain" if best.get("PublicDomain") else "permission needed",
        })
    return out


def load_fishbase_pictures(cache_dir):
    """The pinned FishBase/SeaLifeBase picture tables (fetch_fishbase_pictures.py)."""
    import pyarrow.parquet as pq  # real runs only; tests pass rows directly
    rows = []
    for database, short in (("FishBase", "fb"), ("SeaLifeBase", "slb")):
        table = pq.read_table(Path(cache_dir) / f"{short}-picturesmain.parquet").to_pylist()
        for p in table:
            rows.append({"database": database, "SpecCode": p["SpecCode"], "PicGenus": p.get("PicGenus") or "",
                         "PicSpecies": p.get("PicSpecies") or "", "PicName": p.get("PicName") or "",
                         "PictureType": p.get("PictureType"), "AuthName": p.get("AuthName"), "Copyright": p.get("Copyright"),
                         "PublicDomain": bool(p.get("PublicDomain")), "PicPreferred": bool(p.get("PicPreferred")),
                         "BestPic": bool(p.get("BestPic")), "autoctr": p["autoctr"]})
    return rows


# --- manifest and coverage -------------------------------------------------------------

def manifest(selected, policy):
    """Deterministic: species and photos in fixed order, keys sorted, no run timestamp."""
    entries = []
    for row in sorted(selected, key=lambda r: r["speciesID"]):
        for rank, photo in enumerate(row["photos"], start=1):
            entries.append({"speciesID": row["speciesID"], "scientificName": row["scientificName"],
                            "commonName": row["commonName"], "taxonID": f"inaturalist:taxon:{row['taxonID']}",
                            "rank": rank, **photo, "review": {"status": "pending"}})
    return {"schemaVersion": 1, "policy": {k: policy[k] for k in sorted(policy) if k != "note"}, "photos": entries}


def select_cached(client, rows, policy, choices=({}, set())):
    """(selected, pending): every species whose responses are all cached, and the number left
    for a later online run. Uses no network, so it works while the API is rate limiting."""
    selected, pending = [], 0
    for row in rows:
        try:
            selected += select(client, resolve(client, [row]), policy, choices)
        except inat.Offline:
            pending += 1
    return selected, pending


def coverage(selected, permission, pending=0):
    with_inat = {r["speciesID"] for r in selected if r["photos"]}
    with_fishbase = set()  # allowed FishBase photos: none state an allowed licence
    needed = {p["speciesID"] for p in permission}
    statuses = {}
    for r in selected:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
    no_photo = [r for r in selected if r["speciesID"] not in with_inat | with_fishbase | needed]
    return {
        "schemaVersion": 1, "species": len(selected), "notYetFetched": pending,
        "withINaturalistPhoto": len(with_inat), "withFishBasePhoto": len(with_fishbase),
        "permissionNeeded": sum(p["action"] == "permission needed" for p in permission),
        "confirmPublicDomain": sum(p["action"] == "confirm public domain" for p in permission),
        "noPhoto": len(no_photo),
        "photosSelected": sum(len(r["photos"]) for r in selected),
        "taxonMatch": dict(sorted(statuses.items())),
        "laterDecisionOnly": sum(1 for r in selected if not r["photos"] and (r.get("laterDecisionPhotoObservations") or 0) > 0),
        "flaggedTaxa": [{"speciesID": r["speciesID"], "scientificName": r["scientificName"], "status": r["status"],
                         "candidates": r.get("candidates", [])} for r in selected if r["status"] in (SYNONYM, AMBIGUOUS)],
    }


def permission_csv(rows):
    buffer = io.StringIO()
    fields = ["scientificName", "commonName", "database", "photographer", "photoPageURL", "copyrightStatement", "action", "speciesID"]
    writer = csv.DictWriter(buffer, fieldnames=fields, lineterminator="\n", extrasaction="ignore")
    writer.writeheader()
    for row in sorted(rows, key=lambda r: (r["scientificName"], r["speciesID"])):
        writer.writerow(row)
    return buffer.getvalue()


def write_json(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=1, sort_keys=True, ensure_ascii=False) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--offline", action="store_true", help="use cached responses only")
    parser.add_argument("--species", nargs="*", help="limit to these species IDs (default: all of Global)")
    parser.add_argument("--policy", default=licences.POLICY_PATH)
    parser.add_argument("--output", default=OUT)
    parser.add_argument("--report", default=REPORT)
    parser.add_argument("--fishbase-cache", default=OUT / "fishbase-cache")
    parser.add_argument("--cached-only", action="store_true",
                        help="no requests: process the species whose responses are cached and count the rest as not yet fetched")
    parser.add_argument("--choices", default=CHOICES, help="the reviewer's chosen and excluded photos")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="seconds between iNaturalist requests; raise it if the API answers 429")
    args = parser.parse_args()
    policy = licences.load_policy(args.policy)
    rows = species()
    if args.species:
        wanted = {s.lower() for s in args.species}
        rows = [r for r in rows if r["speciesID"] in wanted]
    log = lambda message: print(message, file=sys.stderr, flush=True)  # noqa: E731
    client = inat.Client(CACHE, offline=args.offline or args.cached_only, minimum_interval=args.interval, log=log)
    if args.cached_only:
        selected, pending = select_cached(client, rows, policy, load_choices(args.choices))
    else:
        selected, pending = select(client, resolve(client, rows), policy, load_choices(args.choices)), 0
    missing = [r for r in selected if not r["photos"]]
    permission = fishbase_fallback(missing, load_fishbase_pictures(args.fishbase_cache)) if missing else []
    output = Path(args.output)
    write_json(output / "PhotoManifest.json", manifest(selected, policy))
    (output / "PermissionNeeded.csv").write_text(permission_csv(permission))
    report = coverage(selected, permission, pending)
    write_json(args.report, report)
    print(json.dumps({k: v for k, v in report.items() if k != "flaggedTaxa"}, sort_keys=True), f"requests={client.requests}")


if __name__ == "__main__":
    main()
