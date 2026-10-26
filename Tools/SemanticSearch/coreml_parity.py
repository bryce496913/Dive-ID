#!/usr/bin/env python3
"""Numerical parity between the reference encoder and the converted Core ML encoder.

The tolerances and probe texts are frozen in coreml-parity.v1.json. The comparison is
plain Python, so it is unit-tested in the dependency-free tooling suite; producing Core ML
vectors needs macOS (coremltools can only run predictions there), and provisioning fails
closed when any check does not pass.
"""
import json
import math
from pathlib import Path

SPEC_PATH = Path(__file__).resolve().parent / "coreml-parity.v1.json"
TOLERANCE_KEYS = (
    "coreMLCosineMinimum", "coreMLMaxAbsoluteDifference", "unitNormMaxDeviation",
    "paddingInvarianceCosineMinimum", "retrievalTopK", "retrievalTopKOverlapMinimum",
    "retrievalScoreMaxAbsoluteDifference", "retrievalTop1RequiredWhenReferenceMarginAtLeast",
)


def load_spec(path=SPEC_PATH):
    spec = json.loads(Path(path).read_text(encoding="utf-8"))
    if spec.get("schemaVersion") != 1:
        raise ValueError("unsupported Core ML parity schemaVersion")
    missing = [key for key in TOLERANCE_KEYS if key not in spec.get("tolerances", {})]
    if missing:
        raise ValueError(f"Core ML parity tolerances missing: {missing}")
    if not spec.get("probes") or any(not isinstance(text, str) for text in spec["probes"]):
        raise ValueError("Core ML parity needs non-empty string probes")
    return spec


def masked_mean_normalized(hidden, mask):
    """Masked mean pooling then L2 normalization, as CoreMLSemanticEmbeddingProvider.pool:
    only positions whose mask is 1 are read, so padded positions can never leak in.
    ``hidden`` is one row of floats per token (a nested list or a 2-D array)."""
    mask = list(mask)
    rows = hidden.tolist() if hasattr(hidden, "tolist") else hidden
    if len(rows) != len(mask):
        raise ValueError("hidden states and mask lengths differ")
    kept = [row for row, flag in zip(rows, mask) if flag == 1]
    count = max(1, len(kept))
    pooled = [sum(column) / count for column in zip(*kept)] if kept else [0.0] * len(rows[0])
    if not all(math.isfinite(value) for value in pooled):
        raise ValueError("pooled embedding is not finite")
    norm = math.sqrt(sum(value * value for value in pooled))
    if not math.isfinite(norm) or norm <= 0:
        raise ValueError("pooled embedding has no direction")
    return [value / norm for value in pooled]


def _dot(a, b):
    return math.fsum(x * y for x, y in zip(a, b))


def _norm(a):
    return math.sqrt(_dot(a, a))


def _cosine(a, b):
    return _dot(a, b) / (_norm(a) * _norm(b))


def _ranking(query, index_ids, index_matrix):
    # As SemanticRetrievalRuntime: cosine, then species ID ascending on ties.
    query_norm = _norm(query)
    scores = [_dot(query, row) / query_norm for row in index_matrix]
    order = sorted(range(len(index_ids)), key=lambda row: (-scores[row], index_ids[row]))
    return [(index_ids[row], scores[row]) for row in order]


def evaluate(spec, reference, coreml, unpadded_reference, index_ids, index_vectors):
    """Compare per-probe vectors and retrieval; returns a report whose status is
    "passed" only when every probe meets every frozen tolerance.

    ``reference``, ``coreml`` and ``unpadded_reference`` are lists of vectors, one per
    probe in spec order; ``index_vectors`` are the bundled document vectors."""
    tolerance = spec["tolerances"]
    probes = spec["probes"]
    if not (len(reference) == len(coreml) == len(unpadded_reference) == len(probes)):
        raise ValueError("one reference, Core ML and unpadded vector is required per probe")
    if not index_ids or len(index_ids) != len(index_vectors):
        raise ValueError("index IDs and vectors must be non-empty and aligned")
    matrix = []
    for vector in index_vectors:
        norm = _norm(vector)
        if not math.isfinite(norm) or norm <= 0:
            raise ValueError("index vector has no direction")
        matrix.append([value / norm for value in vector])
    top_k = min(int(tolerance["retrievalTopK"]), len(index_ids))
    rows, failures = [], []
    for position, text in enumerate(probes):
        ours, theirs, unpadded = ([float(value) for value in vector] for vector in
                                  (reference[position], coreml[position], unpadded_reference[position]))
        problems = []
        if len(ours) != len(theirs) or len(ours) != len(unpadded):
            row = {"probe": position, "failures": ["dimension mismatch"]}
            rows.append(row); failures.append(row); continue
        if not all(math.isfinite(value) for value in ours + theirs + unpadded) or not (_norm(ours) and _norm(theirs) and _norm(unpadded)):
            row = {"probe": position, "failures": ["non-finite vector"]}
            rows.append(row); failures.append(row); continue
        cosine = _cosine(ours, theirs)
        max_abs = max(abs(x - y) for x, y in zip(ours, theirs))
        norm_deviation = max(abs(_norm(ours) - 1), abs(_norm(theirs) - 1))
        padding_cosine = _cosine(ours, unpadded)
        expected = _ranking(ours, index_ids, matrix)
        actual = _ranking(theirs, index_ids, matrix)
        expected_top = [identifier for identifier, _ in expected[:top_k]]
        actual_top = [identifier for identifier, _ in actual[:top_k]]
        overlap = len(set(expected_top) & set(actual_top))
        actual_scores = dict(actual)
        score_difference = max(abs(score - actual_scores[identifier]) for identifier, score in expected[:top_k])
        margin = expected[0][1] - expected[1][1] if len(expected) > 1 else float("inf")
        if cosine < tolerance["coreMLCosineMinimum"]: problems.append("cosine")
        if max_abs > tolerance["coreMLMaxAbsoluteDifference"]: problems.append("max absolute difference")
        if norm_deviation > tolerance["unitNormMaxDeviation"]: problems.append("unit norm")
        if padding_cosine < tolerance["paddingInvarianceCosineMinimum"]: problems.append("padding invariance")
        if overlap < min(int(tolerance["retrievalTopKOverlapMinimum"]), top_k): problems.append("top-k overlap")
        if score_difference > tolerance["retrievalScoreMaxAbsoluteDifference"]: problems.append("retrieval score")
        if margin >= tolerance["retrievalTop1RequiredWhenReferenceMarginAtLeast"] and expected_top[0] != actual_top[0]:
            problems.append("top-1")
        row = {"probe": position, "cosine": cosine, "maxAbsoluteDifference": max_abs,
               "unitNormDeviation": norm_deviation, "paddingInvarianceCosine": padding_cosine,
               "topKOverlap": overlap, "retrievalScoreMaxAbsoluteDifference": score_difference,
               "referenceTop1Margin": margin, "top1Matches": expected_top[0] == actual_top[0],
               "referenceTopK": expected_top, "referenceTopKScores": [score for _, score in expected[:top_k]],
               "failures": problems}
        rows.append(row)
        if problems: failures.append(row)
    summary = {
        "minimumCosine": min((row["cosine"] for row in rows if "cosine" in row), default=None),
        "maximumAbsoluteDifference": max((row["maxAbsoluteDifference"] for row in rows if "maxAbsoluteDifference" in row), default=None),
        "minimumTopKOverlap": min((row["topKOverlap"] for row in rows if "topKOverlap" in row), default=None),
        "top1Agreement": sum(1 for row in rows if row.get("top1Matches")),
    }
    return {"status": "failed" if failures else "passed", "probes": len(probes), "failedProbes": len(failures),
            "tolerances": dict(tolerance), "summary": summary, "rows": rows}
