"""Write the enriched draft records into the Global pack (Debug-only while they are drafts).

Reads Data/GlobalMarine/FishBase/Drafts/batch-*.json and RiskReport.json and writes
DiveID/Resources/IdentificationPacks/Global/Creatures.json and its PackManifest.json.

- Records whose source lacks a required field (risk flag `missing_required`) are left
  out: the app rejects a pack containing them. They stay in staging.
- `similarSpecies` references to records outside the written pack are dropped, because
  the app requires every reference to resolve within the pack.
- Every record must be a draft. Release builds expose only verified records, so this
  pack stays hidden from Release.
- Manifest counts are derived from the written records, and the whole pack is validated
  with the Swift-compatible validator before anything is written. Output is
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

PACK = REPO / "DiveID/Resources/IdentificationPacks/Global"
PACK_VERSION = 2  # 1 was the empty placeholder


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


def manifest_for(records, template):
    reviewed = sum(r["review"]["status"] in ("sourceChecked", "verified") for r in records)
    eligible = sum(r["review"]["status"] == "verified" and bool(r["categories"]) for r in records)
    manifest = dict(template)
    manifest.update({"packVersion": PACK_VERSION, "speciesCount": len(records), "includedRecordCount": len(records),
                     "humanReviewedRecordCount": reviewed, "publicationEligibleRecordCount": eligible,
                     "shortDescription": "Worldwide draft catalogue from FishBase and SeaLifeBase; not verified for publication"})
    return manifest


def creatures_text(records):
    return "[\n" + ",\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n]\n"


def write_if_changed(path, text):
    if path.exists() and path.read_text() == text:
        return "unchanged"
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(text)
    temp.replace(path)
    return "written"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--staging", default=REPO / "Data/GlobalMarine/FishBase")
    parser.add_argument("--pack", default=PACK)
    args = parser.parse_args(argv)
    staging, pack = Path(args.staging), Path(args.pack)
    drafts = [r for f in sorted(glob.glob(str(staging / "Drafts" / "batch-*.json"))) for r in json.loads(Path(f).read_text())]
    risk = json.loads((staging / "RiskReport.json").read_text())["records"]
    records, excluded, dropped = compose(drafts, risk)
    manifest = manifest_for(records, json.loads((pack / "PackManifest.json").read_text()))
    catalogue_validation.validate_catalogue(records, manifest)  # raises on any error; nothing written
    actions = {"Creatures.json": write_if_changed(pack / "Creatures.json", creatures_text(records)),
               "PackManifest.json": write_if_changed(pack / "PackManifest.json", json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")}
    print(json.dumps({"records": len(records), "excludedMissingRequired": excluded, "droppedSimilarSpeciesReferences": dropped,
                      "files": actions}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
