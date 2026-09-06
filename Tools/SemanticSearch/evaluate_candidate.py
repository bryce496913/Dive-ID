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
    model = manifest["model"]
    for key in ("source", "revision", "license", "identifier"):
        if not model.get(key): raise ValueError(f"model.{key} must be pinned before evaluation")
    if manifest["schemaVersion"] != 1: raise ValueError("unsupported manifest schema")
    for item in manifest["artifacts"]:
        if set(("path", "sha256")) - item.keys() or not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
            raise ValueError("every artifact needs path and SHA-256")


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
