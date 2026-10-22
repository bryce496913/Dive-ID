"""Write the FishBase-built records into the Global pack and the two regional packs.

Reads Data/GlobalMarine/FishBase/Drafts/batch-*.json and RiskReport.json and writes
Creatures.json and PackManifest.json for Global, Caribbean and Tropical Pacific.

- Every pack uses the same record text: Caribbean and Tropical Pacific are the subsets
  of the Global records the merge plan keeps for that pack (MergePlan.csv, role keep).
  One review therefore covers a species in every pack it appears in, because approval
  is tied to the record's content fingerprint.

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
import csv
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
PACKS_ROOT = REPO / "DiveID/Resources/IdentificationPacks"
MERGE_PLAN = REPO / "Data/GlobalMarine/FishBase/MergePlan.csv"
# Regional pack directory -> (merge-plan pack name, base version). Version 4 is the
# FishBase rebuild (3 was the last hand-written / field-guide version); each approved
# batch adds 1, as for Global, so changed review status always changes the version.
REGIONAL = {"Caribbean": ("Caribbean", 4), "TropicalPacific": ("TropicalPacific", 4)}
REGIONAL_TEXT = {
    "Caribbean": {"shortDescription": "Caribbean starter catalogue from FishBase and SeaLifeBase"},
    "TropicalPacific": {
        "shortDescription": "Tropical Pacific records from FishBase and SeaLifeBase; not verified for publication",
        "geographicScope": "Species with source-supported Tropical Pacific presence, described from FishBase and "
                           "SeaLifeBase; inclusion does not verify identity, biology or abundance."},
}


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


def regional_members(plan_rows, pack_name):
    """UUIDs the merge plan keeps for one regional pack."""
    return {r["plannedUUID"] for r in plan_rows if r["role"] == "keep" and r["pack"] == pack_name}


def regional_records(records, members):
    """The regional subset, in Global order. similarSpecies must resolve inside the pack,
    so references to species outside it are dropped (as compose does for Global)."""
    subset = [json.loads(json.dumps(r)) for r in records if r["id"] in members]
    ids = {r["id"] for r in subset}
    for r in subset:
        kept = [x for x in r["similarSpecies"] if x["speciesID"] in ids]
        if len(kept) != len(r["similarSpecies"]) and not kept and "similarSpecies" in r["dataSources"][0]["reviewedFields"]:
            r["dataSources"][0]["reviewedFields"].remove("similarSpecies")
        r["similarSpecies"] = kept
    return subset


def regional_manifest(records, template, directory, approved_batches=0):
    """Counts come from the records; the pack keeps its id, name and region aliases."""
    reviewed = sum(r["review"]["status"] in ("sourceChecked", "verified") for r in records)
    eligible = sum(r["review"]["status"] == "verified" and bool(r["categories"]) for r in records)
    manifest = dict(template)
    manifest.update(REGIONAL_TEXT.get(directory, {}))
    manifest.update({"packVersion": REGIONAL[directory][1] + approved_batches, "speciesCount": len(records),
                     "includedRecordCount": len(records), "humanReviewedRecordCount": reviewed,
                     "publicationEligibleRecordCount": eligible})
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
    parser.add_argument("--packs-root", default=PACKS_ROOT, help="parent of the regional pack directories")
    parser.add_argument("--merge-plan", default=MERGE_PLAN)
    args = parser.parse_args(argv)
    staging, pack = Path(args.staging), Path(args.pack)
    drafts = [r for f in sorted(glob.glob(str(staging / "Drafts" / "batch-*.json"))) for r in json.loads(Path(f).read_text())]
    risk = json.loads((staging / "RiskReport.json").read_text())["records"]
    records, excluded, dropped = compose(drafts, risk)
    reviews, review_report = apply_reviews(records, Path(args.batches))
    manifest = manifest_for(records, json.loads((pack / "PackManifest.json").read_text()), len(review_report["approvedBatches"]))
    catalogue_validation.validate_catalogue(records, manifest)  # raises on any error; nothing written
    plan_rows = list(csv.DictReader(open(args.merge_plan, newline="")))
    regional = {}
    for directory, (pack_name, _) in REGIONAL.items():
        target = Path(args.packs_root) / directory
        subset = regional_records(records, regional_members(plan_rows, pack_name))
        if not subset:
            raise SystemExit(f"{directory}: the merge plan keeps no published record for this pack")
        regional_manifest_ = regional_manifest(subset, json.loads((target / "PackManifest.json").read_text()), directory,
                                               len(review_report["approvedBatches"]))
        catalogue_validation.validate_catalogue(subset, regional_manifest_)  # validate every pack before writing any
        regional[directory] = (target, subset, regional_manifest_)
    action = write_pack(pack, creatures_text(records), json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    regional_actions = {directory: {"records": len(subset), "verified": sum(r["review"]["status"] == "verified" for r in subset),
                                    "pack": write_pack(target, creatures_text(subset),
                                                       json.dumps(m, indent=2, ensure_ascii=False) + "\n")}
                        for directory, (target, subset, m) in regional.items()}
    applied = Path(args.batches) / "AppliedApprovals.json"
    if not applied.exists() or applied.read_text() != applied_approvals_text(reviews, review_report):
        applied.write_text(applied_approvals_text(reviews, review_report))
    print(json.dumps({"records": len(records), "excludedMissingRequired": excluded, "droppedSimilarSpeciesReferences": dropped,
                      "verifiedByBatchReview": len(reviews), "batchReview": review_report,
                      "pack": action, "regionalPacks": regional_actions}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
