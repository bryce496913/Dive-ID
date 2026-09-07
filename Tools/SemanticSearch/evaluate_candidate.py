#!/usr/bin/env python3
"""Audit a frozen real-model evaluation without ever manufacturing embeddings.

The inputs are deliberately produced by the reference and Core ML runners.  This
tool only validates provenance and computes parity/ranking evidence from them.
"""
import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_json(path: Path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def load_jsonl(path: Path):
    with path.open(encoding="utf-8") as stream:
        return [json.loads(line) for line in stream if line.strip()]


def verify_files(manifest, root: Path):
    failures = []
    for item in manifest["artifacts"]:
        path = root / item["path"]
        if not path.is_file():
            failures.append(f"missing artifact: {item['path']}")
        elif sha256(path) != item["sha256"]:
            failures.append(f"checksum mismatch: {item['path']}")
    return failures


def cosine(left, right):
    if len(left) != len(right) or not left:
        raise ValueError("incompatible empty or differently sized vectors")
    dot = sum(a * b for a, b in zip(left, right))
    ln = math.sqrt(sum(a * a for a in left)); rn = math.sqrt(sum(b * b for b in right))
    if not ln or not rn or not all(math.isfinite(x) for x in left + right):
        raise ValueError("vectors must be finite and non-zero")
    return dot / (ln * rn)


def parity(reference_rows, converted_rows, catalogue_rows, tolerances):
    def unique(rows, label):
        mapped = {row["id"]: row for row in rows}
        if len(mapped) != len(rows): raise ValueError(f"duplicate {label} id")
        return mapped
    reference, converted = unique(reference_rows, "reference"), unique(converted_rows, "Core ML")
    if reference.keys() != converted.keys(): raise ValueError("reference/Core ML example IDs differ")
    catalogue = unique(catalogue_rows, "catalogue")
    max_abs, minimum_cosine, ranking_changes, examples = 0.0, 1.0, 0, []
    for identifier in sorted(reference):
        left, right = reference[identifier]["vector"], converted[identifier]["vector"]
        if len(left) != len(right): raise ValueError(f"dimension mismatch for {identifier}")
        difference = max((abs(a - b) for a, b in zip(left, right)), default=0.0)
        similarity = cosine(left, right)
        ref_rank = sorted(catalogue, key=lambda key: (-cosine(left, catalogue[key]["vector"]), key))
        coreml_rank = sorted(catalogue, key=lambda key: (-cosine(right, catalogue[key]["vector"]), key))
        changed = ref_rank[:10] != coreml_rank[:10]
        ranking_changes += int(changed); max_abs = max(max_abs, difference); minimum_cosine = min(minimum_cosine, similarity)
        examples.append({"id": identifier, "maximumAbsoluteError": difference,
                         "cosineSimilarity": similarity, "top10RankingChanged": changed,
                         "referenceTop10": ref_rank[:10], "coreMLTop10": coreml_rank[:10]})
    passed = (max_abs <= tolerances["maximumAbsoluteError"] and
              minimum_cosine >= tolerances["minimumCosineSimilarity"] and
              ranking_changes <= tolerances["maximumTop10RankingChanges"])
    return {"examples": len(reference), "maximumAbsoluteError": max_abs,
            "minimumCosineSimilarity": minimum_cosine, "top10RankingChanges": ranking_changes,
            "tolerances": tolerances, "status": "pass" if passed else "fail", "details": examples}


def validate_manifest(manifest):
    required = ["schemaVersion", "frozenAtUTC", "model", "conversion", "preprocessing",
                "ranking", "acceptanceCriteria", "catalogue", "datasets", "artifacts"]
    missing = [key for key in required if key not in manifest]
    if missing: raise ValueError("manifest missing: " + ", ".join(missing))
    if manifest["schemaVersion"] != 1: raise ValueError("unsupported manifest schema")
    if not isinstance(manifest["frozenAtUTC"], str) or not re.fullmatch(
            r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", manifest["frozenAtUTC"]):
        raise ValueError("frozenAtUTC must be an ISO-8601 UTC timestamp ending in Z")
    # datetime performs the calendar validation which a shape-only regular expression cannot.
    from datetime import datetime
    try: datetime.fromisoformat(manifest["frozenAtUTC"].replace("Z", "+00:00"))
    except ValueError as error: raise ValueError("frozenAtUTC is not a valid timestamp") from error

    def require_object(parent, name, fields):
        value = parent.get(name)
        if not isinstance(value, dict) or not value:
            raise ValueError(f"{name} must be a non-empty object")
        for field in fields:
            if field not in value or value[field] is None or value[field] == "":
                raise ValueError(f"{name}.{field} is required")
        return value

    model = require_object(manifest, "model", ("source", "revision", "identifier", "license", "version"))
    if str(model["revision"]).lower() in ("main", "master", "head", "latest") or not re.fullmatch(r"[0-9a-f]{7,64}", str(model["revision"])):
        raise ValueError("model.revision must be an immutable hexadecimal revision")
    conversion = require_object(manifest, "conversion", ("tool", "toolVersion", "sourceFormat", "coreMLFormat",
        "minimumDeploymentTarget", "computePrecision", "expectedInputs", "expectedOutputs"))
    for field in ("expectedInputs", "expectedOutputs"):
        features = conversion[field]
        if not isinstance(features, list) or not features:
            raise ValueError(f"conversion.{field} must contain feature declarations")
        for feature in features:
            if not isinstance(feature, dict) or any(not feature.get(key) for key in ("name", "dataType", "shape")):
                raise ValueError(f"conversion.{field} entries require name, dataType, and shape")
            if not isinstance(feature["shape"], list) or not feature["shape"] or any(
                    not isinstance(value, int) or isinstance(value, bool) or value <= 0 for value in feature["shape"]):
                raise ValueError(f"conversion.{field} shape must contain positive integer dimensions")

    preprocessing = require_object(manifest, "preprocessing", ("tokenizerIdentifier", "tokenizerRevision",
        "vocabularySHA256", "lowercase", "stripAccents", "maximumSequenceLength", "truncation",
        "specialTokens", "prefixes", "pooling", "normalization"))
    if not re.fullmatch(r"[0-9a-f]{64}", str(preprocessing["vocabularySHA256"])):
        raise ValueError("preprocessing.vocabularySHA256 must be a lowercase SHA-256")
    if not all(isinstance(preprocessing[key], bool) for key in ("lowercase", "stripAccents")):
        raise ValueError("preprocessing lowercase and stripAccents must be booleans")
    if not isinstance(preprocessing["maximumSequenceLength"], int) or isinstance(preprocessing["maximumSequenceLength"], bool) or preprocessing["maximumSequenceLength"] < 2:
        raise ValueError("preprocessing.maximumSequenceLength must be at least two")
    if preprocessing["truncation"] not in ("beginning", "end"):
        raise ValueError("preprocessing.truncation must be beginning or end")
    require_object(preprocessing, "specialTokens", ("cls", "separator", "padding", "unknown"))
    require_object(preprocessing, "prefixes", ("query", "document"))
    if preprocessing["pooling"] not in ("cls", "meanMasked", "modelOutput"):
        raise ValueError("preprocessing.pooling is unsupported")
    if preprocessing["normalization"] != "l2":
        raise ValueError("preprocessing.normalization must be l2")

    ranking = require_object(manifest, "ranking", ("contractVersion", "candidateLimit", "parameters"))
    if not isinstance(ranking["contractVersion"], int) or ranking["contractVersion"] <= 0:
        raise ValueError("ranking.contractVersion must be positive")
    if not isinstance(ranking["candidateLimit"], int) or isinstance(ranking["candidateLimit"], bool) or ranking["candidateLimit"] <= 0:
        raise ValueError("ranking.candidateLimit must be positive")
    if not isinstance(ranking["parameters"], dict) or not ranking["parameters"]:
        raise ValueError("ranking.parameters must freeze concrete values")

    acceptance = require_object(manifest, "acceptanceCriteria", ("benchmarkGateVersion", "numericalParity"))
    if not isinstance(acceptance["benchmarkGateVersion"], int) or acceptance["benchmarkGateVersion"] <= 0:
        raise ValueError("acceptanceCriteria.benchmarkGateVersion must be positive")
    numerical = require_object(acceptance, "numericalParity", ("maximumAbsoluteError", "minimumCosineSimilarity", "maximumTop10RankingChanges"))
    for key in ("maximumAbsoluteError", "minimumCosineSimilarity", "maximumTop10RankingChanges"):
        value = numerical[key]
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
            raise ValueError(f"acceptanceCriteria.numericalParity.{key} must be finite")
    if numerical["maximumAbsoluteError"] < 0 or not -1 <= numerical["minimumCosineSimilarity"] <= 1:
        raise ValueError("numerical parity error must be non-negative and cosine must be within [-1, 1]")
    if not isinstance(numerical["maximumTop10RankingChanges"], int) or numerical["maximumTop10RankingChanges"] < 0:
        raise ValueError("maximumTop10RankingChanges must be a non-negative integer")

    catalogue = require_object(manifest, "catalogue", ("packID", "packVersion", "speciesCount",
        "searchDocumentSchemaVersion", "fingerprint"))
    for key in ("packVersion", "speciesCount", "searchDocumentSchemaVersion"):
        if not isinstance(catalogue[key], int) or isinstance(catalogue[key], bool) or catalogue[key] <= 0:
            raise ValueError(f"catalogue.{key} must be a positive integer")
    if not re.fullmatch(r"[0-9a-f]{64}", str(catalogue["fingerprint"])):
        raise ValueError("catalogue.fingerprint must be a lowercase SHA-256")

    datasets = manifest["datasets"]
    if not isinstance(datasets, list) or not datasets:
        raise ValueError("datasets must contain explicit dataset declarations")
    for dataset in datasets:
        if not isinstance(dataset, dict) or any(not dataset.get(key) for key in ("identifier", "fingerprint", "role")):
            raise ValueError("every dataset needs identifier, fingerprint, and role")
        if not re.fullmatch(r"[0-9a-f]{64}", str(dataset["fingerprint"])):
            raise ValueError("dataset fingerprints must be lowercase SHA-256 values")

    artifacts = manifest["artifacts"]
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("artifacts must contain at least one artifact")
    paths = []
    for item in artifacts:
        if not isinstance(item, dict) or any(not item.get(key) for key in ("path", "sha256", "role")):
            raise ValueError("every artifact needs path, SHA-256, and role/type")
        if not re.fullmatch(r"[0-9a-f]{64}", str(item["sha256"])):
            raise ValueError("artifact SHA-256 values must be lowercase hexadecimal")
        paths.append(item["path"])
    if len(paths) != len(set(paths)):
        raise ValueError("artifact paths must be unique")


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True, help="frozen candidate manifest")
    parser.add_argument("--root", type=Path, default=Path.cwd(), help="base for artifact paths")
    parser.add_argument("--reference", type=Path, help="reference query embeddings JSONL")
    parser.add_argument("--coreml", type=Path, help="Core ML query embeddings JSONL from physical hardware")
    parser.add_argument("--catalogue-vectors", type=Path, help="reference catalogue embeddings JSONL")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        manifest = load_json(args.manifest); validate_manifest(manifest)
        checks = verify_files(manifest, args.root)
        result = {"schemaVersion": 1, "manifestSHA256": sha256(args.manifest),
                  "artifactVerification": {"status": "pass" if not checks else "fail", "failures": checks},
                  "parity": {"status": "not-evaluated", "reason": "both reference and physical-device Core ML exports are required"}}
        supplied = [args.reference, args.coreml, args.catalogue_vectors]
        if any(supplied) and not all(supplied): raise ValueError("parity requires --reference, --coreml, and --catalogue-vectors together")
        if all(supplied):
            result["parity"] = parity(load_jsonl(args.reference), load_jsonl(args.coreml),
                                      load_jsonl(args.catalogue_vectors), manifest["acceptanceCriteria"]["numericalParity"])
        encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
        if args.output: args.output.write_text(encoded, encoding="utf-8")
        else: print(encoded, end="")
        return 0 if result["artifactVerification"]["status"] == "pass" and result["parity"]["status"] != "fail" else 1
    except (KeyError, ValueError, OSError, json.JSONDecodeError) as error:
        print(f"evaluation input error: {error}", file=sys.stderr); return 2


if __name__ == "__main__": raise SystemExit(main())
