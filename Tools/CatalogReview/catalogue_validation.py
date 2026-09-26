"""Swift-compatible catalogue decoding and domain validation.

This module deliberately validates JSON values without coercion.  Its field table is
derived from ``LocalSpeciesProfile`` and the nested Codable types in
``OfflineIdentificationPack.swift``; the domain checks mirror
``BundleMarineSpeciesCatalogRepository.validate``.
"""
from __future__ import annotations

import math
import re
import uuid
from datetime import datetime


VOCABULARY = {
    "colors": {"black", "blue", "brown", "gray", "green", "olive", "orange", "red", "silver", "white", "yellow"},
    "markings": {"barbels", "beak", "eye stripe", "fin edge", "patches", "saddles", "shell", "spines", "spots", "stripes", "tail", "teeth"},
    "bodyShapes": {"compressed", "disk", "elongated", "flat", "oval", "pointed", "robust", "round", "serpentine", "torpedo"},
    "habitats": {"anemone", "deep", "lagoon", "mangrove", "open water", "reef", "rubble", "sand", "seagrass", "shallow", "surface", "wall", "wreck"},
    "categories": {"crustacean", "eel", "fish", "mollusk", "octopus", "ray", "seahorse", "shark", "squid", "turtle"},
    "behaviors": {"anemone association", "bottom-swimming", "burrowing", "cleaning", "feeding", "grazing", "hiding", "hovering", "open-water cruising", "resting", "schooling", "solitary", "swimming"},
    "regions": {"aruba", "atlantic", "bahamas", "belize", "bermuda", "bonaire", "british virgin islands", "caribbean", "cayman islands", "cozumel", "curaçao", "curacao", "dominican republic", "fiji", "florida", "gulf of mexico", "hawaii", "indian", "indo-pacific", "jamaica", "pacific", "puerto rico", "turks and caicos", "us virgin islands", "western atlantic"},
}

STRING_ARRAYS = {"aliases", "categories", "colors", "markings", "bodyShapes", "habitats", "regions", "behaviors", "keywords", "distinguishingFeatures", "cautions", "subregions", "mouthAndHeadShape", "finAndSpineClues"}
REQUIRED_STRINGS = {"id", "commonName", "scientificName", "summary", "typicalHabitat", "geographicRange"}
OPTIONAL_STRINGS = {"imageAssetName", "regionalOccurrenceNotes", "tailShape"}
OPTIONAL_NUMBERS = {"minimumSizeCentimeters", "maximumSizeCentimeters", "minimumDepthMeters", "maximumDepthMeters"}
OCCURRENCES = {"unknown", "common", "regular", "occasional", "rare", "seasonal", "introduced"}
LIFE_STAGES = {"juvenile", "intermediate", "adult", "initialPhase", "terminalPhase"}
MEASUREMENT_TYPES = {"totalLength", "forkLength", "discWidth", "carapaceLength"}
REVIEW_STATUSES = {"draft", "sourceChecked", "verified"}
IMAGE_LICENSES = {"CC0", "Public Domain", "CC BY 4.0", "CC BY"}


class CatalogueValidationError(ValueError):
    def __init__(self, diagnostics):
        self.diagnostics = diagnostics
        super().__init__("invalid catalogue:\n- " + "\n- ".join(diagnostics))


def _actual(value):
    if value is None: return "null"
    if isinstance(value, bool): return f"boolean {value!r}"
    if isinstance(value, str): return f"string {value!r}"
    if isinstance(value, list): return "array"
    if isinstance(value, dict): return "object"
    return f"{type(value).__name__} {value!r}"


def _error(errors, species_id, path, expected, value):
    errors.append(f"speciesID {species_id!r}, field {path}: expected {expected}; actual {_actual(value)}")


def _string(errors, sid, path, value, optional=False):
    if value is None and optional: return
    if not isinstance(value, str): _error(errors, sid, path, "string" + (" or null" if optional else ""), value)


def _number(errors, sid, path, value):
    if value is None: return
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        _error(errors, sid, path, "finite number or null", value)


def _string_array(errors, sid, path, value, nullable=True):
    if value is None and nullable: return
    if not isinstance(value, list):
        _error(errors, sid, path, "array of strings" + (" or null" if nullable else ""), value); return
    for index, item in enumerate(value):
        if not isinstance(item, str): _error(errors, sid, f"{path}[{index}]", "string", item)


def _object(errors, sid, path, value, nullable=True):
    if value is None and nullable: return False
    if not isinstance(value, dict): _error(errors, sid, path, "object" + (" or null" if nullable else ""), value); return False
    return True


def _date(errors, sid, path, value, optional=True):
    if value is None and optional: return
    if not isinstance(value, str): _error(errors, sid, path, "ISO-8601 date string or null", value); return
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})", value):
        _error(errors, sid, path, "ISO-8601 date string or null", value); return
    try: datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError: _error(errors, sid, path, "ISO-8601 date string or null", value)


def _enum(errors, sid, path, value, allowed, nullable=False):
    if value is None and nullable: return
    if not isinstance(value, str) or value not in allowed:
        _error(errors, sid, path, "one of " + ", ".join(sorted(allowed)) + (", or null" if nullable else ""), value)


def validate_record(record, position=1):
    errors = []
    if not isinstance(record, dict):
        return [f"speciesID '<record {position}>', field $: expected object; actual {_actual(record)}"]
    sid = record.get("id", f"<record {position}>")
    for field in REQUIRED_STRINGS: _string(errors, sid, field, record.get(field))
    if isinstance(record.get("id"), str):
        try: uuid.UUID(record["id"])
        except ValueError: _error(errors, sid, "id", "UUID string", record["id"])
    for field in OPTIONAL_STRINGS:
        if field in record: _string(errors, sid, field, record[field], optional=True)
    for field in STRING_ARRAYS:
        if field in record: _string_array(errors, sid, field, record[field])
    for field in OPTIONAL_NUMBERS:
        if field in record: _number(errors, sid, field, record[field])
    _enum(errors, sid, "regionalOccurrence", record.get("regionalOccurrence", "regular"), OCCURRENCES, nullable=True)

    variants = record.get("appearanceVariants", [])
    if variants is not None:
        if not isinstance(variants, list): _error(errors, sid, "appearanceVariants", "array of objects or null", variants)
        else:
            for i, value in enumerate(variants):
                path = f"appearanceVariants[{i}]"
                if not _object(errors, sid, path, value, False): continue
                _string(errors, sid, path + ".id", value.get("id")); _enum(errors, sid, path + ".lifeStage", value.get("lifeStage"), LIFE_STAGES)
                for field in ("colors", "markings", "bodyShapes", "distinguishingFeatures"): _string_array(errors, sid, path + "." + field, value.get(field), False)
                for field in ("minimumSizeCentimeters", "maximumSizeCentimeters"): _number(errors, sid, path + "." + field, value.get(field))
                _string(errors, sid, path + ".description", value.get("description"))

    similar = record.get("similarSpecies", [])
    if similar is not None:
        if not isinstance(similar, list): _error(errors, sid, "similarSpecies", "array of objects or null", similar)
        else:
            for i, value in enumerate(similar):
                path = f"similarSpecies[{i}]"
                if not _object(errors, sid, path, value, False): continue
                _string(errors, sid, path + ".speciesID", value.get("speciesID")); _string(errors, sid, path + ".distinguishingText", value.get("distinguishingText"))
                if isinstance(value.get("speciesID"), str):
                    try: uuid.UUID(value["speciesID"])
                    except ValueError: _error(errors, sid, path + ".speciesID", "UUID string", value["speciesID"])

    sources = record.get("dataSources", [])
    if sources is not None:
        if not isinstance(sources, list): _error(errors, sid, "dataSources", "array of objects or null", sources)
        else:
            for i, value in enumerate(sources):
                path = f"dataSources[{i}]"
                if not _object(errors, sid, path, value, False): continue
                for f in ("sourceName", "sourceURL"): _string(errors, sid, path + "." + f, value.get(f))
                for f in ("stableSourceID", "citationReference", "sourceLicense"): _string(errors, sid, path + "." + f, value.get(f), True)
                _string_array(errors, sid, path + ".reviewedFields", value.get("reviewedFields"), False)
                _date(errors, sid, path + ".accessedDate", value.get("accessedDate"))

    review = record.get("review")
    if _object(errors, sid, "review", review):
        _enum(errors, sid, "review.status", review.get("status"), REVIEW_STATUSES)
        for field in ("reviewerNotes", "verifiedBy"): _string(errors, sid, "review." + field, review.get(field), True)
        _date(errors, sid, "review.reviewDate", review.get("reviewDate"))

    taxonomy = record.get("taxonomy")
    if _object(errors, sid, "taxonomy", taxonomy):
        aphia = taxonomy.get("wormsAphiaID")
        if aphia is not None and (isinstance(aphia, bool) or not isinstance(aphia, int)): _error(errors, sid, "taxonomy.wormsAphiaID", "integer or null", aphia)
        for field in ("scientificNameAuthority", "taxonomicClass", "order", "family", "genus"): _string(errors, sid, "taxonomy." + field, taxonomy.get(field), True)
        for field in ("acceptedScientificName", "sourceScientificName"): _string(errors, sid, "taxonomy." + field, taxonomy.get(field))

    measurements = record.get("measurements")
    if _object(errors, sid, "measurements", measurements):
        for field in ("typicalObservedMinimumCentimeters", "typicalObservedMaximumCentimeters", "maximumRecordedCentimeters"): _number(errors, sid, "measurements." + field, measurements.get(field))
        _enum(errors, sid, "measurements.type", measurements.get("type"), MEASUREMENT_TYPES)
    image = record.get("bundledImage")
    if _object(errors, sid, "bundledImage", image):
        for field in ("fileName", "alternativeText", "creatorName", "sourceName", "sourceURL", "licenseName", "licenseURL"):
            _string(errors, sid, "bundledImage." + field, image.get(field))
    return errors


def validate_catalogue(records, manifest=None):
    errors = []
    if not isinstance(records, list): raise CatalogueValidationError([f"field $: expected array of records; actual {_actual(records)}"])
    for i, record in enumerate(records, 1): errors.extend(validate_record(record, i))
    valid = [r for r in records if isinstance(r, dict)]
    ids = {}
    canonical_common, canonical_scientific = {}, {}
    for i, r in enumerate(valid, 1):
        sid = r.get("id", f"<record {i}>")
        if sid in ids: errors.append(f"speciesID {sid!r}, field id: expected unique stable ID; actual duplicate of record {ids[sid]}")
        else: ids[sid] = i
        for field, seen in (("commonName", canonical_common), ("scientificName", canonical_scientific)):
            value = r.get(field); normalized = value.strip().lower() if isinstance(value, str) else ""
            if not normalized: errors.append(f"speciesID {sid!r}, field {field}: expected nonempty string; actual {_actual(value)}")
            elif normalized in seen: errors.append(f"speciesID {sid!r}, field {field}: expected unique canonical identity; actual duplicates speciesID {seen[normalized]!r}")
            else: seen[normalized] = sid
    canonical = set(canonical_common) | set(canonical_scientific)
    for r in valid:
        sid = r.get("id");
        if isinstance(r.get("summary"), str) and not r["summary"].strip(): errors.append(f"speciesID {sid!r}, field summary: expected nonempty string; actual string {r['summary']!r}")
        if r.get("geographicRange") == "": errors.append(f"speciesID {sid!r}, field geographicRange: expected nonempty string; actual string ''")
        if not isinstance(r.get("distinguishingFeatures"), list) or not r.get("distinguishingFeatures"): errors.append(f"speciesID {sid!r}, field distinguishingFeatures: expected nonempty array; actual {_actual(r.get('distinguishingFeatures'))}")
        if not isinstance(r.get("dataSources"), list) or not r.get("dataSources"): errors.append(f"speciesID {sid!r}, field dataSources: expected nonempty array; actual {_actual(r.get('dataSources'))}")
        for low, high in (("minimumSizeCentimeters", "maximumSizeCentimeters"), ("minimumDepthMeters", "maximumDepthMeters")):
            a, b = r.get(low), r.get(high)
            if isinstance(a, (int, float)) and not isinstance(a, bool) and a < 0: errors.append(f"speciesID {sid!r}, field {low}: expected nonnegative number; actual {a!r}")
            if isinstance(b, (int, float)) and not isinstance(b, bool) and b < 0: errors.append(f"speciesID {sid!r}, field {high}: expected nonnegative number; actual {b!r}")
            if all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in (a, b)) and a > b: errors.append(f"speciesID {sid!r}, field {low}: expected value <= {high}; actual {a!r} > {b!r}")
        for field, allowed in VOCABULARY.items():
            if isinstance(r.get(field), list):
                for j, value in enumerate(r[field]):
                    if isinstance(value, str) and value.lower() not in allowed: _error(errors, sid, f"{field}[{j}]", "supported controlled-vocabulary value", value)
        own = {str(r.get("commonName", "")).strip().lower(), str(r.get("scientificName", "")).strip().lower()}
        for j, alias in enumerate(r.get("aliases") or []):
            normalized = alias.strip().lower() if isinstance(alias, str) else ""
            if normalized and normalized in canonical and normalized not in own: errors.append(f"speciesID {sid!r}, field aliases[{j}]: expected no collision with another canonical identity; actual {alias!r}")
        review = r.get("review") or {}
        if isinstance(review, dict) and review.get("status") == "verified":
            for field in ("verifiedBy", "reviewerNotes"):
                if not isinstance(review.get(field), str) or not review[field].strip(): errors.append(f"speciesID {sid!r}, field review.{field}: expected nonempty review evidence; actual {_actual(review.get(field))}")
            if review.get("reviewDate") is None: errors.append(f"speciesID {sid!r}, field review.reviewDate: expected review evidence date; actual null")
            evidence = any(isinstance(s, dict) and all(isinstance(s.get(f), str) and s[f].strip() for f in ("stableSourceID", "sourceURL", "citationReference")) and isinstance(s.get("reviewedFields"), list) and bool(s["reviewedFields"]) for s in (r.get("dataSources") or []))
            if not evidence: errors.append(f"speciesID {sid!r}, field dataSources: expected verified source evidence (stableSourceID, sourceURL, citationReference, reviewedFields); actual none")
        for i, comp in enumerate(r.get("similarSpecies") or []):
            if isinstance(comp, dict) and (comp.get("speciesID") == sid or comp.get("speciesID") not in ids or not comp.get("distinguishingText")):
                errors.append(f"speciesID {sid!r}, field similarSpecies[{i}]: expected existing different species ID and nonempty distinguishingText; actual invalid reference")
        variant_ids = set()
        for i, variant in enumerate(r.get("appearanceVariants") or []):
            if not isinstance(variant, dict): continue
            variant_id = variant.get("id")
            if variant_id in variant_ids: errors.append(f"speciesID {sid!r}, field appearanceVariants[{i}].id: expected unique variant ID; actual duplicate {variant_id!r}")
            variant_ids.add(variant_id)
            a, b = variant.get("minimumSizeCentimeters"), variant.get("maximumSizeCentimeters")
            if isinstance(a, (int, float)) and not isinstance(a, bool) and a < 0: errors.append(f"speciesID {sid!r}, field appearanceVariants[{i}].minimumSizeCentimeters: expected nonnegative number; actual {a!r}")
            if isinstance(b, (int, float)) and not isinstance(b, bool) and b < 0: errors.append(f"speciesID {sid!r}, field appearanceVariants[{i}].maximumSizeCentimeters: expected nonnegative number; actual {b!r}")
            if all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in (a, b)) and a > b: errors.append(f"speciesID {sid!r}, field appearanceVariants[{i}].minimumSizeCentimeters: expected value <= maximumSizeCentimeters; actual {a!r} > {b!r}")
            for field in ("colors", "markings", "bodyShapes"):
                for j, value in enumerate(variant.get(field) or []):
                    if isinstance(value, str) and value.lower() not in VOCABULARY[field]: _error(errors, sid, f"appearanceVariants[{i}].{field}[{j}]", "supported controlled-vocabulary value", value)
        image = r.get("bundledImage")
        if isinstance(image, dict):
            for field in ("alternativeText", "creatorName", "sourceName"):
                if isinstance(image.get(field), str) and not image[field].strip(): errors.append(f"speciesID {sid!r}, field bundledImage.{field}: expected nonempty attribution; actual {image[field]!r}")
            filename = image.get("fileName", "")
            if isinstance(filename, str) and (not filename.strip() or "/" in filename or "\\" in filename or filename.rsplit(".", 1)[-1].lower() not in {"svg", "png", "jpg", "jpeg"}): errors.append(f"speciesID {sid!r}, field bundledImage.fileName: expected safe supported image filename; actual {filename!r}")
            for field in ("sourceURL", "licenseURL"):
                value = image.get(field, "")
                if isinstance(value, str) and not re.match(r"^https?://[^/]+", value, re.I): errors.append(f"speciesID {sid!r}, field bundledImage.{field}: expected HTTP(S) URL; actual {value!r}")
            if image.get("licenseName") not in IMAGE_LICENSES: _error(errors, sid, "bundledImage.licenseName", "supported image license", image.get("licenseName"))
    if manifest is not None:
        if not isinstance(manifest, dict): errors.append(f"field manifest: expected object; actual {_actual(manifest)}")
        else:
            count = len(records); reviewed = sum((r.get("review") or {}).get("status") in ("sourceChecked", "verified") for r in valid); eligible = sum((r.get("review") or {}).get("status") == "verified" and bool(r.get("categories")) for r in valid)
            expected = {"speciesCount": count, "includedRecordCount": count, "humanReviewedRecordCount": reviewed, "publicationEligibleRecordCount": eligible}
            for field, value in expected.items():
                if manifest.get(field) != value: errors.append(f"field manifest.{field}: expected integer {value}; actual {_actual(manifest.get(field))}")
            if manifest.get("schemaVersion") != 1: errors.append(f"field manifest.schemaVersion: expected integer 1; actual {_actual(manifest.get('schemaVersion'))}")
            if isinstance(manifest.get("packVersion"), bool) or not isinstance(manifest.get("packVersion"), int) or manifest.get("packVersion", 0) <= 0: errors.append(f"field manifest.packVersion: expected positive integer; actual {_actual(manifest.get('packVersion'))}")
            for field in ("id", "displayName", "shortDescription", "geographicScope", "speciesResourceName", "imageSubdirectory"):
                _string(errors, "<manifest>", "manifest." + field, manifest.get(field))
            _string_array(errors, "<manifest>", "manifest.regionAliases", manifest.get("regionAliases"), False)
            if not isinstance(manifest.get("includedWithApp"), bool): _error(errors, "<manifest>", "manifest.includedWithApp", "boolean", manifest.get("includedWithApp"))
            _date(errors, "<manifest>", "manifest.lastDataReviewDate", manifest.get("lastDataReviewDate"))
    if errors: raise CatalogueValidationError(errors)
