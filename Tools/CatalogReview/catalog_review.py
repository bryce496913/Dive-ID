#!/usr/bin/env python3
"""Apply durable, source-bound human catalogue review decisions.

Automated import and tests never create approvals. A decision is effective only when
its stable ID, source identity, and reviewed-content SHA-256 still match.
"""
from __future__ import annotations
import argparse, hashlib, json
from pathlib import Path

PUBLICATION_FIELDS = (
    "commonName", "scientificName", "aliases", "categories", "colors", "markings",
    "bodyShapes", "habitats", "regions", "behaviors", "keywords",
    "minimumSizeCentimeters", "maximumSizeCentimeters", "minimumDepthMeters",
    "maximumDepthMeters", "summary", "distinguishingFeatures", "typicalHabitat",
    "geographicRange", "cautions", "regionalOccurrence", "regionalOccurrenceNotes",
    "subregions", "appearanceVariants", "similarSpecies", "taxonomy", "measurements",
    "tailShape", "mouthAndHeadShape", "finAndSpineClues", "dataSources",
)

def content_fingerprint(record):
    payload = {key: record.get(key) for key in PUBLICATION_FIELDS}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()

def source_identity(record):
    return sorted((s.get("stableSourceID"), s.get("citationReference")) for s in record.get("dataSources", []))

def apply_decisions(records, decision_document):
    decisions = {item["speciesID"]: item for item in decision_document.get("decisions", [])}
    outcomes = []
    for record in records:
        decision = decisions.get(record["id"])
        if not decision:
            continue
        if decision.get("sourceIdentity") != [list(x) for x in source_identity(record)]:
            outcomes.append({"speciesID": record["id"], "state": "stale", "reason": "source identity changed"}); continue
        corrected = dict(record)
        for field, value in decision.get("corrections", {}).items():
            if field not in PUBLICATION_FIELDS:
                raise ValueError(f"unsupported correction field: {field}")
            corrected[field] = value
        actual = content_fingerprint(corrected)
        if decision.get("reviewedContentFingerprint") != actual:
            outcomes.append({"speciesID": record["id"], "state": "stale", "reason": "reviewed content changed", "actualFingerprint": actual}); continue
        status = decision.get("decision", "draft")
        unresolved = decision.get("unresolvedQuestions", [])
        if status == "verified" and (unresolved or not corrected.get("categories")):
            outcomes.append({"speciesID": record["id"], "state": "blocked", "reason": "identification-critical questions remain"}); continue
        if status not in ("draft", "sourceChecked", "verified"):
            raise ValueError(f"unsupported decision: {status}")
        corrected["review"] = {"status": status, "reviewerNotes": decision.get("reviewerNotes"),
                               "reviewDate": decision.get("reviewDate"), "verifiedBy": decision.get("reviewerIdentity")}
        record.clear(); record.update(corrected)
        outcomes.append({"speciesID": record["id"], "state": "applied", "decision": status})
    return outcomes

def update_manifest(manifest, records):
    reviewed = sum(r.get("review", {}).get("status") in ("sourceChecked", "verified") for r in records)
    eligible = sum(r.get("review", {}).get("status") == "verified" and bool(r.get("categories")) for r in records)
    manifest.update(includedRecordCount=len(records), humanReviewedRecordCount=reviewed,
                    publicationEligibleRecordCount=eligible, speciesCount=len(records))

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--decisions", type=Path, default=Path("Data/CatalogReview/ReviewDecisions.json"))
    args=parser.parse_args()
    records=json.loads((args.pack/"Creatures.json").read_text())
    manifest=json.loads((args.pack/"PackManifest.json").read_text())
    document=json.loads(args.decisions.read_text())
    outcomes=apply_decisions(records, document); update_manifest(manifest, records)
    (args.pack/"Creatures.json").write_text(json.dumps(records, indent=2, ensure_ascii=False)+"\n")
    (args.pack/"PackManifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False)+"\n")
    print(json.dumps(outcomes, indent=2))
if __name__ == "__main__": main()
