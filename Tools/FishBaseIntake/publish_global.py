"""Write the enriched draft records into the Global pack (Debug-only while they are drafts).

Reads Data/GlobalMarine/FishBase/Drafts/batch-*.json and RiskReport.json and writes
DiveID/Resources/IdentificationPacks/Global/Creatures.json and its PackManifest.json.

- Records whose source lacks a required field (risk flag `missing_required`) are left
  out: the app rejects a pack containing them. They stay in staging.
- `similarSpecies` references to records outside the written pack are dropped, because
  the app requires every reference to resolve within the pack.
- Every staged record must be a draft. A record becomes verified only through a batch
  review overlay (Tools/CatalogReview/global_batches.py) whose manifest is the newest
  for its batch and whose fingerprint still matches the record's content. Release
  builds expose only verified records, so the pack stays hidden from Release until
  the first batch is approved.
- Manifest counts are derived from the written records, and the whole pack is validated
  with the Swift-compatible validator before anything is written. The two files are
  replaced as a pair with rollback (Tools/CatalogReview/paired_write.py). Output is
  deterministic; an unchanged pack is not rewritten.
"""
import argparse
import glob
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "CatalogReview"))
import catalogue_validation  # noqa: E402
import global_batches  # noqa: E402
import paired_write  # noqa: E402

PACK = REPO / "DiveID/Resources/IdentificationPacks/Global"
PACK_VERSION = 2  # 1 was the empty placeholder; each approved batch adds 1


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


def manifest_for(records, template, approved_batches=0):
    """Counts come from the records. The pack stays "(Experimental)" until every record
    is publication-eligible; its version rises with each approved batch, whose review
    changes the records."""
    reviewed = sum(r["review"]["status"] in ("sourceChecked", "verified") for r in records)
    eligible = sum(r["review"]["status"] == "verified" and bool(r["categories"]) for r in records)
    complete = bool(records) and eligible == len(records)
    manifest = dict(template)
    manifest.update({"packVersion": PACK_VERSION + approved_batches, "speciesCount": len(records), "includedRecordCount": len(records),
                     "humanReviewedRecordCount": reviewed, "publicationEligibleRecordCount": eligible,
                     "displayName": "Global" if complete else "Global (Experimental)",
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
    args = parser.parse_args(argv)
    staging, pack = Path(args.staging), Path(args.pack)
    drafts = [r for f in sorted(glob.glob(str(staging / "Drafts" / "batch-*.json"))) for r in json.loads(Path(f).read_text())]
    risk = json.loads((staging / "RiskReport.json").read_text())["records"]
    records, excluded, dropped = compose(drafts, risk)
    reviews, review_report = apply_reviews(records, Path(args.batches))
    manifest = manifest_for(records, json.loads((pack / "PackManifest.json").read_text()), len(review_report["approvedBatches"]))
    catalogue_validation.validate_catalogue(records, manifest)  # raises on any error; nothing written
    action = write_pack(pack, creatures_text(records), json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"records": len(records), "excludedMissingRequired": excluded, "droppedSimilarSpeciesReferences": dropped,
                      "verifiedByBatchReview": len(reviews), "batchReview": review_report,
                      "pack": action}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
