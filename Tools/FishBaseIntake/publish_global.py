"""Write the enriched draft records into the Global pack (Debug-only while they are drafts).

Reads Data/GlobalMarine/FishBase/Drafts/batch-*.json and RiskReport.json and writes
DiveID/Resources/IdentificationPacks/Global/Creatures.json and its PackManifest.json.

- Records whose source lacks a required field (risk flag `missing_required`) are left
  out: the app rejects a pack containing them. They stay in staging.
- `similarSpecies` references to records outside the written pack are dropped, because
  the app requires every reference to resolve within the pack.
- The 8 Caribbean species come from the bundled Caribbean pack, with its reviewed
  field-guide (v3) text, not from FishBase: rebuilding them from FishBase lost the clues
  divers describe (owner decision, 2026-10-23). They are appended after every FishBase
  record, unchanged except that in Global each is a draft (a regional approval does not
  carry over; Global approval comes only from a recorded batch decision) and has no
  bundled image (the artwork files live in the Caribbean pack; no Global record has one).
- Every staged record must be a draft. A record becomes verified only through a batch
  review overlay (Tools/CatalogReview/global_batches.py) whose manifest is the newest
  for its batch and whose fingerprint still matches the record's content. Release
  builds expose only verified records, and only from packs whose definition is
  `availableInRelease`; Global is not (GlobalRegion.swift), so approvals alone never
  put it in Release.
- Species photos (Tools/SpeciesPhotos) are bundled only once approved in photo review
  (Tools/CatalogReview/photo_batches.py): a record gets `bundledImage`, and its
  thumbnail is copied into the pack's Images/, only while a current approval covers the
  photo's exact attribution and thumbnail bytes. An unapproved photo never reaches the
  pack, so it can never reach Release. Photo files no longer approved are removed.
- Manifest counts are derived from the written records, and the whole pack is validated
  with the Swift-compatible validator before anything is written. The two files are
  replaced as a pair with rollback (Tools/CatalogReview/paired_write.py). Output is
  deterministic; an unchanged pack is not rewritten.
"""
import argparse
import glob
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "CatalogReview"))
import catalogue_validation  # noqa: E402
import global_batches  # noqa: E402
import paired_write  # noqa: E402
import photo_batches  # noqa: E402

PACK = REPO / "DiveID/Resources/IdentificationPacks/Global"
CARIBBEAN = REPO / "DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json"
CARIBBEAN_REVIEW = {"status": "draft", "reviewDate": None, "verifiedBy": None,
                    "reviewerNotes": "Caribbean pack record (field-guide text), carried into Global unchanged; "
                                     "awaiting Global batch review."}
PACK_VERSION = 2  # 1 was the empty placeholder; each approved batch adds 1


def carried_caribbean(drafts, caribbean):
    """The Caribbean pack's records as Global drafts, to append after the FishBase drafts.
    The FishBase build reserves these species' names and never builds them."""
    built = {r["id"] for r in drafts} & {r["id"] for r in caribbean}
    if built:
        raise SystemExit(f"Caribbean species also built from FishBase: {', '.join(sorted(built))}")
    return [dict(json.loads(json.dumps(r)), review=dict(CARIBBEAN_REVIEW), bundledImage=None) for r in caribbean]


def compose(drafts, risk_records):
    """Return (records, excluded ids, dropped similar-species references)."""
    excluded = sorted(r["id"] for r in drafts
                      if any(f.startswith("missing_required") for f in risk_records.get(r["id"], {}).get("flags", [])))
    records = [json.loads(json.dumps(r)) for r in drafts if r["id"] not in set(excluded)]
    ids = {r["id"] for r in records}
    dropped = 0
    for r in records:
        if r["review"]["status"] != "draft":
            raise SystemExit(f"{r['id']}: only draft records may be published to the Global pack")
        kept = [s for s in r["similarSpecies"] if s["speciesID"] in ids and s["speciesID"] != r["id"]]
        dropped += len(r["similarSpecies"]) - len(kept)
        r["similarSpecies"] = kept
        if not kept and "similarSpecies" in r["dataSources"][0]["reviewedFields"]:
            r["dataSources"][0]["reviewedFields"].remove("similarSpecies")
    return records, excluded, dropped


def apply_reviews(records, batches):
    """Mark records verified where a current batch approval still covers their content."""
    reviews, report = global_batches.approved_reviews(records, batches)
    for record in records:
        if record["id"] in reviews:
            record["review"] = reviews[record["id"]]
    return reviews, report


def applied_approvals_text(reviews, report):
    """What the pack actually applied: approved IDs with their review method, and the
    approved records whose content changed since (stale, so not approved)."""
    return json.dumps({"approved": {i: reviews[i]["reviewMethod"] for i in sorted(reviews)},
                       "approvedBatches": report["approvedBatches"], "stale": report["staleRecords"]}, indent=1) + "\n"


PHOTO_FILE = re.compile(r"[0-9a-f-]{36}-inat-[0-9]+\.jpg")


def alternative_text(record):
    """From the species name and its visible features (the first distinguishing feature)."""
    text = f"Photo of {record['commonName']} ({record['scientificName']})"
    features = record.get("distinguishingFeatures") or []
    return text + (f": {features[0].rstrip('.')}." if features else ".")


def bundled_image(photo, thumbnail, record):
    return {"fileName": thumbnail["fileName"], "alternativeText": alternative_text(record),
            "creatorName": photo["creatorName"], "sourceName": photo["sourceName"], "sourceURL": photo["sourcePageURL"],
            "licenseName": photo["licenseName"], "licenseURL": photo["licenseURL"], "photoURL": photo["photoURL"],
            "photoID": photo["photoID"], "observationID": photo["observationID"], "retrievedDate": photo["retrievedOn"]}


def apply_photos(records, photo_manifest, thumbnails, batches):
    """Give each record its best approved photo (lowest rank). Returns ({image fileName:
    thumbnail path} to bundle, report). Records without an approved photo keep none."""
    photo_manifest, thumbnails = Path(photo_manifest), Path(thumbnails)
    if not photo_manifest.exists():
        return {}, {"approvedPhotos": 0, "bundledPhotos": 0, "stalePhotos": [], "supersededDecisions": []}
    photos = json.loads(photo_manifest.read_text())["photos"]
    index = photo_batches.thumbnail_index(thumbnails)
    approvals, report = photo_batches.approved_photos(photos, index, batches)
    best = {}
    for photo in sorted(photos, key=lambda p: (p["speciesID"], p["rank"])):
        if photo["photoID"] in approvals and photo["photoID"] in index:
            best.setdefault(photo["speciesID"].lower(), photo)
    files = {}
    for record in records:
        photo = best.get(record["id"].lower())
        if photo:
            thumbnail = index[photo["photoID"]]
            record["bundledImage"] = bundled_image(photo, thumbnail, record)
            files[thumbnail["fileName"]] = thumbnails / thumbnail["fileName"]
    return files, dict(report, bundledPhotos=len(files))


def sync_images(image_dir, files, expected_sha256=None):
    """Copy the approved thumbnails into the pack and remove photo files no longer approved.
    Only files named like intake photos are ever removed. Staging thumbnails aren't committed,
    so on a fresh checkout a pack image already in place is kept when its SHA-256 matches the
    thumbnail index (expected_sha256: {fileName: sha256})."""
    image_dir = Path(image_dir)
    for name, source in sorted(files.items()):
        target = image_dir / name
        if not Path(source).exists():
            expected = (expected_sha256 or {}).get(name)
            if target.exists() and expected and hashlib.sha256(target.read_bytes()).hexdigest() == expected:
                continue
            raise FileNotFoundError(f"{name}: no staging thumbnail and no matching pack image; run Tools/SpeciesPhotos/thumbnails.py")
        if not (target.exists() and target.read_bytes() == Path(source).read_bytes()):
            image_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
    removed = sorted(p.name for p in image_dir.glob("*.jpg") if PHOTO_FILE.fullmatch(p.name) and p.name not in files) if image_dir.exists() else []
    for name in removed:
        (image_dir / name).unlink()
    return removed


def manifest_for(records, template, approved_batches=0):
    """Counts come from the records. The pack is named "Global" even while it holds drafts
    (Bryce, 2026-10-23): Release lists only its approved records, and the description
    gives the approved count until every record is publication-eligible. The version
    rises with each recorded batch approval, whose review changes the records. approved_batches counts every approval ever recorded, so
    a new generation that supersedes an approved one never lowers the version."""
    reviewed = sum(r["review"]["status"] in ("sourceChecked", "verified") for r in records)
    eligible = sum(r["review"]["status"] == "verified" and bool(r["categories"]) for r in records)
    complete = bool(records) and eligible == len(records)
    manifest = dict(template)
    manifest.update({"packVersion": PACK_VERSION + approved_batches, "speciesCount": len(records), "includedRecordCount": len(records),
                     "humanReviewedRecordCount": reviewed, "publicationEligibleRecordCount": eligible,
                     "displayName": "Global",
                     "shortDescription": "Worldwide catalogue from FishBase and SeaLifeBase" if complete else
                     f"Worldwide catalogue from FishBase and SeaLifeBase; {eligible} of {len(records)} records approved for publication"})
    return manifest


def creatures_text(records):
    return "[\n" + ",\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n]\n"


def write_pack(pack, creatures, manifest_text):
    """Write Creatures.json and PackManifest.json as one unit (paired_write: both or
    neither). An unchanged pack is not rewritten."""
    targets = (Path(pack) / "Creatures.json", Path(pack) / "PackManifest.json")
    texts = (creatures, manifest_text)
    if all(t.exists() and t.read_bytes() == text.encode() for t, text in zip(targets, texts)):
        return "unchanged"
    paired_write.replace_file_pair(targets, tuple(text.encode() for text in texts))
    return "written"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--staging", default=REPO / "Data/GlobalMarine/FishBase")
    parser.add_argument("--pack", default=PACK)
    parser.add_argument("--batches", default=global_batches.BATCHES)
    parser.add_argument("--caribbean", default=CARIBBEAN, help="the bundled Caribbean pack's Creatures.json")
    parser.add_argument("--photo-manifest", default=photo_batches.PHOTO_MANIFEST)
    parser.add_argument("--thumbnails", default=photo_batches.THUMBNAILS)
    parser.add_argument("--photo-batches", default=photo_batches.BATCHES)
    args = parser.parse_args(argv)
    staging, pack = Path(args.staging), Path(args.pack)
    drafts = [r for f in sorted(glob.glob(str(staging / "Drafts" / "batch-*.json"))) for r in json.loads(Path(f).read_text())]
    drafts += carried_caribbean(drafts, json.loads(Path(args.caribbean).read_text()))
    risk = json.loads((staging / "RiskReport.json").read_text())["records"]
    records, excluded, dropped = compose(drafts, risk)
    reviews, review_report = apply_reviews(records, Path(args.batches))
    photo_files, photo_report = apply_photos(records, args.photo_manifest, args.thumbnails, args.photo_batches)
    manifest = manifest_for(records, json.loads((pack / "PackManifest.json").read_text()), review_report["approvalsRecorded"])
    image_dir = pack / manifest["imageSubdirectory"]
    hashes = {e["fileName"]: e["sha256"] for e in photo_batches.thumbnail_index(args.thumbnails).values()}
    sync_images(image_dir, photo_files, hashes)  # copies approved thumbnails before validation checks they exist
    catalogue_validation.validate_catalogue(records, manifest, pack)  # raises on any error; pack files not written
    action = write_pack(pack, creatures_text(records), json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    applied = Path(args.batches) / "AppliedApprovals.json"
    if not applied.exists() or applied.read_text() != applied_approvals_text(reviews, review_report):
        applied.write_text(applied_approvals_text(reviews, review_report))
    print(json.dumps({"records": len(records), "excludedMissingRequired": excluded, "droppedSimilarSpeciesReferences": dropped,
                      "verifiedByBatchReview": len(reviews), "batchReview": review_report, "photoReview": photo_report,
                      "pack": action}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
