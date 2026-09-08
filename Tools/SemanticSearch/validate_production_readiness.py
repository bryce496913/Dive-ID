#!/usr/bin/env python3
"""Validate a versioned semantic production-readiness decision.

This is intentionally fail closed: an absent/unseen dataset, unset threshold, non-passing
engine, or fingerprint mismatch means semantic search cannot be selected as production.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

FINGERPRINT_KEYS = (
    "modelRevision", "tokenizerFingerprint", "preprocessingFingerprint",
    "embeddingIndexFingerprint", "rankingContractFingerprint",
    "catalogueVersion", "freshDatasetVersion",
)
METRICS = (
    "candidateRecallAt10", "candidateRecallAt25", "candidateRecallAt50", "candidateMRR",
    "top1", "top3", "top10", "noMatchCorrectness", "falsePositiveRate",
    "queryEmbeddingLatencyMilliseconds", "retrievalLatencyMilliseconds", "totalLatencyMilliseconds",
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(document):
    errors = []
    if document.get("schemaVersion") != 1:
        errors.append("unsupported schemaVersion")
    identity = document.get("identity", {})
    for key in FINGERPRINT_KEYS:
        if not isinstance(identity.get(key), str) or not identity[key]:
            errors.append(f"identity.{key} is required")
    catalogue = document.get("catalogue", {})
    for key in ("count", "fingerprint", "reviewStateDistribution", "inclusionPolicy"):
        if key not in catalogue:
            errors.append(f"catalogue.{key} is required")
    if not isinstance(catalogue.get("count"), int) or catalogue.get("count", 0) <= 0:
        errors.append("catalogue.count must be positive")
    fresh = document.get("freshDataset", {})
    for key in ("status", "humanReviewed", "previousUses", "leakagePolicy"):
        if key not in fresh:
            errors.append(f"freshDataset.{key} is required")
    forbidden = {"modelSelection", "synonymDevelopment", "rankingTuning", "thresholdTuning", "debugging"}
    uses = fresh.get("previousUses", [])
    if not isinstance(uses, list) or forbidden.intersection(uses):
        errors.append("fresh dataset has prohibited prior use")
    if fresh.get("status") == "available" and fresh.get("humanReviewed") is not True:
        errors.append("available fresh dataset must be human reviewed")
    engines = document.get("engines", {})
    for engine in ("structuredBaseline", "bm25Hybrid", "realSemanticHybrid"):
        record = engines.get(engine)
        if not isinstance(record, dict):
            errors.append(f"engines.{engine} is required")
            continue
        metrics = record.get("metrics", {})
        for metric in METRICS:
            if metric not in metrics:
                errors.append(f"engines.{engine}.metrics.{metric} is required")
    thresholds = document.get("productionThresholds")
    if not isinstance(thresholds, dict):
        errors.append("productionThresholds must be an object (values may be null while unset)")
    approval = document.get("approval", {})
    eligible = (document.get("productionStatus") == "pass" and fresh.get("status") == "available"
                and fresh.get("humanReviewed") is True and isinstance(thresholds, dict)
                and thresholds and all(value is not None for value in thresholds.values())
                and all(engines.get(name, {}).get("status") == "pass" for name in
                        ("structuredBaseline", "bm25Hybrid", "realSemanticHybrid")))
    if eligible:
        if approval.get("status") != "approved":
            errors.append("passing evaluation requires explicit approval")
        approved = approval.get("identity", {})
        for key in FINGERPRINT_KEYS:
            if approved.get(key) != identity.get(key):
                errors.append(f"approval identity mismatch: {key}")
    elif approval.get("status") == "approved":
        errors.append("approval cannot be granted to a non-passing evaluation")
    return errors, eligible and not errors


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("evaluation", type=Path)
    parser.add_argument("--require-approved", action="store_true",
                        help="return failure unless exact artifacts have passing approval")
    args = parser.parse_args(argv)
    try:
        document = json.loads(args.evaluation.read_text(encoding="utf-8"))
        errors, approved = validate(document)
    except (OSError, json.JSONDecodeError) as error:
        print(f"invalid evaluation: {error}", file=sys.stderr); return 2
    result = {"evaluationSHA256": digest(args.evaluation), "schemaValid": not errors,
              "productionSemanticApproved": approved, "errors": errors}
    print(json.dumps(result, indent=2, sort_keys=True))
    if errors: return 2
    return 0 if approved or not args.require_approved else 1


if __name__ == "__main__":
    raise SystemExit(main())
