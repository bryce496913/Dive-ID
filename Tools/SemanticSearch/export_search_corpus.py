#!/usr/bin/env python3
"""Export app-loadable Dive ID catalogue packs as deterministic semantic JSONL."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

DOCUMENT_SCHEMA_VERSION = 1
REQUIRED_RECORD_FIELDS = {
    "id": str, "commonName": str, "scientificName": str, "summary": str,
    "typicalHabitat": str, "geographicRange": str,
}
LIST_FIELDS = (
    "aliases", "categories", "colors", "markings", "bodyShapes", "habitats",
    "regions", "behaviors", "keywords", "distinguishingFeatures", "subregions",
    "appearanceVariants", "mouthAndHeadShape", "finAndSpineClues",
)

class ExportValidationError(ValueError):
    pass

def _normalized_text(values: list[str]) -> str:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        normalized = " ".join(value.split()).lower()
        if normalized and normalized not in seen:
            seen.add(normalized)
            result.append(normalized)
    return " | ".join(result)

def _strings(record: dict[str, Any], field: str) -> list[str]:
    value = record.get(field, [])
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ExportValidationError(f"{field} must be an array of strings")
    return value

def build_search_document(record: dict[str, Any]) -> dict[str, str]:
    """Mirror SpeciesSearchDocumentBuilder without adding facts or synonyms."""
    for field, expected_type in REQUIRED_RECORD_FIELDS.items():
        if field not in record or not isinstance(record[field], expected_type) or not record[field].strip():
            raise ExportValidationError(f"{field} is required and must be a non-empty string")
    for field in LIST_FIELDS:
        if field == "appearanceVariants":
            if not isinstance(record.get(field, []), list):
                raise ExportValidationError(f"{field} must be an array")
        else:
            _strings(record, field)

    optional_tail = record.get("tailShape")
    if optional_tail is not None and not isinstance(optional_tail, str):
        raise ExportValidationError("tailShape must be a string or null")
    variants: list[str] = []
    for index, variant in enumerate(record.get("appearanceVariants", [])):
        if not isinstance(variant, dict) or not isinstance(variant.get("lifeStage"), str) or not isinstance(variant.get("description"), str):
            raise ExportValidationError(f"appearanceVariants[{index}] is invalid")
        variants += [variant["lifeStage"]]
        for field in ("colors", "markings", "bodyShapes"):
            value = variant.get(field, [])
            if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                raise ExportValidationError(f"appearanceVariants[{index}].{field} must be an array of strings")
            variants += value
        variants += [variant["description"]]
        value = variant.get("distinguishingFeatures", [])
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            raise ExportValidationError(f"appearanceVariants[{index}].distinguishingFeatures must be an array of strings")
        variants += value

    sections = {
        "identity": _normalized_text([record["commonName"], record["scientificName"], *_strings(record, "aliases")]),
        "appearance": _normalized_text([
            *_strings(record, "categories"), *_strings(record, "colors"), *_strings(record, "markings"),
            *_strings(record, "bodyShapes"), *_strings(record, "distinguishingFeatures"),
            *([optional_tail] if optional_tail else []), *_strings(record, "mouthAndHeadShape"),
            *_strings(record, "finAndSpineClues"), *_strings(record, "keywords"),
        ]),
        "habitat": _normalized_text([*_strings(record, "habitats"), record["typicalHabitat"]]),
        "behavior": _normalized_text(_strings(record, "behaviors")),
        "range": _normalized_text([*_strings(record, "regions"), *_strings(record, "subregions"), record["geographicRange"]]),
        "life_stage": _normalized_text(variants),
        "general": _normalized_text([record["summary"]]),
    }
    combined = " | ".join(value for value in sections.values() if value)
    fingerprint = hashlib.sha256(f"{DOCUMENT_SCHEMA_VERSION}\n{combined}".encode()).hexdigest()
    return {**sections, "combined": combined, "fingerprint": fingerprint}

def _review_fields(record: dict[str, Any]) -> tuple[str, str, bool, dict[str, Any] | None]:
    review = record.get("review")
    if review is not None and not isinstance(review, dict):
        raise ExportValidationError("review must be an object or null")
    status = (review or {}).get("status", "draft")
    if status not in {"draft", "sourceChecked", "verified"}:
        raise ExportValidationError(f"unknown review status: {status!r}")
    explicit = record.get("humanReviewRequired")
    if explicit is not None and not isinstance(explicit, bool):
        raise ExportValidationError("humanReviewRequired must be boolean when present")
    human_review_required = explicit if explicit is not None else status != "verified"
    tier = "human-review-required" if explicit is True else ("production/reviewed" if status == "verified" else "draft")
    return status, tier, human_review_required, review

def export_pack(pack_directory: Path, output: Path) -> int:
    manifest_path = pack_directory / "PackManifest.json"
    if not manifest_path.is_file():
        raise ExportValidationError(f"missing manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    for field in ("id", "packVersion", "speciesResourceName"):
        if field not in manifest:
            raise ExportValidationError(f"manifest is missing {field}")
    source_path = pack_directory / f"{manifest['speciesResourceName']}.json"
    records = json.loads(source_path.read_text(encoding="utf-8"))
    if not isinstance(records, list):
        raise ExportValidationError("species source must be an array")
    if manifest.get("speciesCount") != len(records):
        raise ExportValidationError("manifest speciesCount does not match source records")

    exported: list[dict[str, Any]] = []
    errors: list[str] = []
    for index, record in enumerate(records):
        try:
            if not isinstance(record, dict):
                raise ExportValidationError("record must be an object")
            document = build_search_document(record)
            status, tier, review_required, review = _review_fields(record)
            exported.append({
                "document_fingerprint": document["fingerprint"],
                "document_schema_version": DOCUMENT_SCHEMA_VERSION,
                "human_review_required": review_required,
                "pack_id": manifest["id"],
                "pack_version": manifest["packVersion"],
                "provenance_tier": tier,
                "review": review,
                "review_status": status,
                "scientific_name": record["scientificName"],
                "search_sections": {key: document[key] for key in ("identity", "appearance", "habitat", "behavior", "range", "life_stage", "general")},
                "search_text": document["combined"],
                "species_id": record["id"],
                "structured": {
                    "behaviors": record.get("behaviors", []), "body_shapes": record.get("bodyShapes", []),
                    "categories": record.get("categories", []), "colors": record.get("colors", []),
                    "depth_meters": {"minimum": record.get("minimumDepthMeters"), "maximum": record.get("maximumDepthMeters")},
                    "habitats": record.get("habitats", []), "markings": record.get("markings", []),
                    "measurements": record.get("measurements"), "regions": record.get("regions", []),
                },
                "common_name": record["commonName"],
            })
        except (ExportValidationError, KeyError) as error:
            errors.append(f"record {index}: {error}")
    if errors:
        raise ExportValidationError("invalid source records:\n" + "\n".join(errors))

    exported.sort(key=lambda item: item["species_id"])
    output.parent.mkdir(parents=True, exist_ok=True)
    data = "".join(json.dumps(item, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n" for item in exported)
    output.write_text(data, encoding="utf-8", newline="\n")
    return len(exported)

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, default=Path("DiveID/Resources/IdentificationPacks/Caribbean"))
    parser.add_argument("--output", type=Path, default=Path("Tools/SemanticSearch/generated/caribbean-search-corpus.jsonl"))
    args = parser.parse_args(argv)
    try:
        count = export_pack(args.pack, args.output)
    except (ExportValidationError, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(f"exported {count} records to {args.output}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
