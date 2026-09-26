#!/usr/bin/env python3
"""Apply durable, source-bound human catalogue review decisions.

Automated import and tests never create approvals. A decision is effective only when
its stable ID, source identity, and reviewed-content SHA-256 still match.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import re
import sys
import tempfile
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalogue_validation import CatalogueValidationError, validate_catalogue

PUBLICATION_FIELDS = (
    "commonName", "scientificName", "aliases", "categories", "colors", "markings",
    "bodyShapes", "habitats", "regions", "behaviors", "keywords",
    "minimumSizeCentimeters", "maximumSizeCentimeters", "minimumDepthMeters",
    "maximumDepthMeters", "summary", "distinguishingFeatures", "typicalHabitat",
    "geographicRange", "cautions", "regionalOccurrence", "regionalOccurrenceNotes",
    "subregions", "appearanceVariants", "similarSpecies", "taxonomy", "measurements",
    "tailShape", "mouthAndHeadShape", "finAndSpineClues", "dataSources",
)
SUPPORTED_DECISIONS = ("draft", "sourceChecked", "verified")
ISO8601_UTC = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
FINGERPRINT = re.compile(r"sha256:[0-9a-f]{64}")


class DecisionValidationError(ValueError):
    """A complete list of problems in a decision overlay."""

    def __init__(self, diagnostics):
        self.diagnostics = diagnostics
        super().__init__("invalid review decisions:\n- " + "\n- ".join(diagnostics))


def content_fingerprint(record):
    payload = {key: record.get(key) for key in PUBLICATION_FIELDS}
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def source_identity(record):
    return sorted((s.get("stableSourceID"), s.get("citationReference")) for s in record.get("dataSources", []))


def _nonempty(value):
    return isinstance(value, str) and bool(value.strip())


def _valid_review_date(value):
    if not isinstance(value, str) or not ISO8601_UTC.fullmatch(value):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def validate_decisions(records, decision_document, catalogue_id):
    """Validate the entire overlay before indexing it or changing any record."""
    errors = []
    if not isinstance(decision_document, dict):
        raise DecisionValidationError(["document must be a JSON object"])
    if decision_document.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    if not _nonempty(catalogue_id):
        errors.append("target catalogue ID is missing")
    intended = decision_document.get("catalogueID")
    if intended != catalogue_id:
        errors.append(f"catalogueID {intended!r} does not match target catalogue {catalogue_id!r}")

    items = decision_document.get("decisions")
    if not isinstance(items, list):
        errors.append("decisions must be an array")
        items = []

    record_positions = {}
    for position, record in enumerate(records, 1):
        species_id = record.get("id") if isinstance(record, dict) else None
        record_positions.setdefault(species_id, []).append(position)

    first_decision = {}
    for index, item in enumerate(items, 1):
        label = f"decision[{index}]"
        if not isinstance(item, dict):
            errors.append(f"{label} must be an object")
            continue
        species_id = item.get("speciesID")
        if not _nonempty(species_id):
            errors.append(f"{label}.speciesID must be a nonempty string")
        elif species_id in first_decision:
            errors.append(
                f"{label} duplicates speciesID {species_id!r} from decision[{first_decision[species_id]}]; "
                "remove one decision (identical duplicates are not allowed)"
            )
        else:
            first_decision[species_id] = index
        matches = record_positions.get(species_id, [])
        if _nonempty(species_id) and not matches:
            errors.append(f"{label} references unknown speciesID {species_id!r} in catalogue {catalogue_id!r}")
        elif len(matches) > 1:
            errors.append(f"{label} speciesID {species_id!r} is ambiguous; catalogue records {matches} share that ID")

        status = item.get("decision")
        if status not in SUPPORTED_DECISIONS:
            errors.append(f"{label}.decision {status!r} is unsupported; expected one of {SUPPORTED_DECISIONS}")
        corrections = item.get("corrections", {})
        if not isinstance(corrections, dict):
            errors.append(f"{label}.corrections must be an object")
        else:
            for field in corrections:
                if field not in PUBLICATION_FIELDS:
                    errors.append(f"{label}.corrections contains unsupported field {field!r}")
        if not isinstance(item.get("sourceIdentity"), list):
            errors.append(f"{label}.sourceIdentity must be an array")
        if not isinstance(item.get("reviewedContentFingerprint"), str) or not FINGERPRINT.fullmatch(item.get("reviewedContentFingerprint", "")):
            errors.append(f"{label}.reviewedContentFingerprint must be a lowercase sha256 fingerprint")
        unresolved = item.get("unresolvedQuestions", [])
        if not isinstance(unresolved, list):
            errors.append(f"{label}.unresolvedQuestions must be an array")

        if status == "verified":
            if not _nonempty(item.get("reviewerIdentity")):
                errors.append(f"{label}.reviewerIdentity is required for verified decisions and cannot be blank")
            if not _nonempty(item.get("reviewerNotes")):
                errors.append(f"{label}.reviewerNotes is required for verified decisions and cannot be blank")
            review_date = item.get("reviewDate")
            if not _valid_review_date(review_date):
                errors.append(f"{label}.reviewDate must use YYYY-MM-DDTHH:MM:SSZ for verified decisions")

    if errors:
        raise DecisionValidationError(errors)
    return items


def _has_swift_review_evidence(record):
    """Mirror BundleMarineSpeciesCatalogRepository's verified-record evidence gate."""
    return any(
        _nonempty(source.get("stableSourceID"))
        and _nonempty(source.get("sourceURL"))
        and _nonempty(source.get("citationReference"))
        and isinstance(source.get("reviewedFields"), list)
        and bool(source["reviewedFields"])
        for source in record.get("dataSources", []) if isinstance(source, dict)
    )


def apply_decisions(records, decision_document, catalogue_id):
    items = validate_decisions(records, decision_document, catalogue_id)
    decisions = {item["speciesID"]: item for item in items}
    outcomes = []
    replacements = []
    for record in records:
        decision = decisions.get(record["id"])
        if not decision:
            continue
        if decision["sourceIdentity"] != [list(x) for x in source_identity(record)]:
            outcomes.append({"speciesID": record["id"], "state": "stale", "reason": "source identity changed"})
            continue
        corrected = copy.deepcopy(record)
        corrected.update(decision.get("corrections", {}))
        actual = content_fingerprint(corrected)
        if decision["reviewedContentFingerprint"] != actual:
            outcomes.append({"speciesID": record["id"], "state": "stale", "reason": "reviewed content changed", "actualFingerprint": actual})
            continue
        status = decision["decision"]
        unresolved = decision.get("unresolvedQuestions", [])
        if status == "verified" and (unresolved or not corrected.get("categories")):
            outcomes.append({"speciesID": record["id"], "state": "blocked", "reason": "identification-critical questions remain"})
            continue
        if status == "verified" and not _has_swift_review_evidence(corrected):
            raise DecisionValidationError([
                f"decision for speciesID {record['id']!r} cannot be verified: no data source has the "
                "stableSourceID, sourceURL, citationReference, and reviewedFields required by Swift validation"
            ])
        corrected["review"] = {"status": status, "reviewerNotes": decision.get("reviewerNotes"),
                               "reviewDate": decision.get("reviewDate"), "verifiedBy": decision.get("reviewerIdentity")}
        replacements.append((record, corrected))
        outcomes.append({"speciesID": record["id"], "state": "applied", "decision": status})
    # Validate a fully corrected in-memory pack before mutating even one caller-owned
    # record.  This catches Codable type failures and cross-record domain failures.
    candidate_records = copy.deepcopy(records)
    by_identity = {id(original): corrected for original, corrected in replacements}
    for index, original in enumerate(records):
        if id(original) in by_identity:
            candidate_records[index] = by_identity[id(original)]
    try:
        validate_catalogue(candidate_records)
    except CatalogueValidationError as error:
        raise DecisionValidationError(error.diagnostics) from error
    # Even record mutation is transactional: every decision and record is prepared first.
    for record, corrected in replacements:
        record.clear()
        record.update(corrected)
    return outcomes


def update_manifest(manifest, records):
    reviewed = sum(r.get("review", {}).get("status") in ("sourceChecked", "verified") for r in records)
    eligible = sum(r.get("review", {}).get("status") == "verified" and bool(r.get("categories")) for r in records)
    manifest.update(includedRecordCount=len(records), humanReviewedRecordCount=reviewed,
                    publicationEligibleRecordCount=eligible, speciesCount=len(records))


def _json_bytes(document):
    return (json.dumps(document, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def replace_catalogue_pair(creatures_path, manifest_path, records, manifest):
    """Stage both outputs, then replace the pair with rollback on any failure."""
    targets = (creatures_path, manifest_path)
    with tempfile.TemporaryDirectory(prefix=".catalog-review-", dir=creatures_path.parent) as temporary:
        stage = Path(temporary)
        staged = (stage / creatures_path.name, stage / manifest_path.name)
        for path, payload in zip(staged, (_json_bytes(records), _json_bytes(manifest))):
            path.write_bytes(payload)
        backups = (stage / (creatures_path.name + ".bak"), stage / (manifest_path.name + ".bak"))
        moved_backups = []
        installed = []
        try:
            for target, backup in zip(targets, backups):
                os.replace(target, backup)
                moved_backups.append((target, backup))
            for source, target in zip(staged, targets):
                os.replace(source, target)
                installed.append(target)
        except BaseException:
            for target in reversed(installed):
                if target.exists():
                    target.unlink()
            for target, backup in reversed(moved_backups):
                if backup.exists():
                    os.replace(backup, target)
            raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", type=Path, required=True)
    parser.add_argument("--decisions", type=Path, default=Path("Data/CatalogReview/ReviewDecisions.json"))
    args = parser.parse_args()
    creatures_path = args.pack / "Creatures.json"
    manifest_path = args.pack / "PackManifest.json"
    records = json.loads(creatures_path.read_text(encoding="utf-8"))
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    document = json.loads(args.decisions.read_text(encoding="utf-8"))
    outcomes = apply_decisions(records, document, manifest.get("id"))
    update_manifest(manifest, records)
    try:
        validate_catalogue(records, manifest)
    except CatalogueValidationError as error:
        raise DecisionValidationError(error.diagnostics) from error
    replace_catalogue_pair(creatures_path, manifest_path, records, manifest)
    print(json.dumps(outcomes, indent=2))


if __name__ == "__main__":
    main()
