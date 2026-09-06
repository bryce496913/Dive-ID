#!/usr/bin/env python3
"""Build a Dive-ID index with a local Hugging Face encoder (developer-only)."""
import argparse, hashlib, json
from pathlib import Path

def catalogue_fingerprint(rows, schema):
    value = "\n".join(sorted(f"{r['species_id'].lower()}:{r['document_fingerprint']}" for r in rows))
    return hashlib.sha256(f"{schema}\n{value}".encode()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--model", required=True, help="local HF model directory; network downloads are not performed by this tool")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    contract = json.loads(args.contract.read_text())
    rows = [json.loads(line) for line in args.corpus.read_text().splitlines() if line.strip()]
    if not rows or len({r["species_id"] for r in rows}) != len(rows): raise SystemExit("empty corpus or duplicate species IDs")
    if contract["pooling"] not in ("meanMasked", "cls"): raise SystemExit("modelOutput pooling cannot be reproduced from token hidden states")
    if not contract["normalizeL2"]: raise SystemExit("Dive-ID contract requires L2 normalization")

    try:
        import torch
        from transformers import AutoModel, AutoTokenizer
    except ImportError as exc:
        raise SystemExit("Install developer dependencies: pip install torch transformers") from exc
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    model = AutoModel.from_pretrained(args.model, local_files_only=True).eval()
    texts = [contract["documentPrefix"] + r["search_text"] for r in rows]
    vectors = []
    with torch.inference_mode():
        for text in texts:
            encoded = tokenizer(text, return_tensors="pt", max_length=contract["maximumSequenceLength"],
                                truncation=True, padding="max_length")
            hidden = model(**encoded).last_hidden_state
            if contract["pooling"] == "cls": pooled = hidden[:, 0, :]
            else:
                mask = encoded["attention_mask"].unsqueeze(-1)
                pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1)
            vector = torch.nn.functional.normalize(pooled, p=2, dim=1)[0].tolist()
            if len(vector) != contract["embeddingDimension"]: raise SystemExit("encoder dimension does not match contract")
            vectors.append(vector)

    schema = rows[0]["document_schema_version"]
    if any(r["document_schema_version"] != schema for r in rows): raise SystemExit("mixed document schemas")
    pack_id, pack_version = rows[0]["pack_id"], rows[0]["pack_version"]
    if any((r["pack_id"], r["pack_version"]) != (pack_id, pack_version) for r in rows): raise SystemExit("mixed packs")
    output = {"metadata": {"modelIdentifier": contract["modelIdentifier"], "modelVersion": contract["modelVersion"],
        "embeddingDimension": contract["embeddingDimension"], "searchDocumentSchemaVersion": schema,
        "documentFingerprint": catalogue_fingerprint(rows, schema), "packID": pack_id, "packVersion": pack_version,
        "tokenizerIdentifier": contract["tokenizerIdentifier"], "preprocessingIdentifier": contract["preprocessingIdentifier"],
        "indexFormatVersion": 1}, "records": [
        {"speciesID": row["species_id"], "documentFingerprint": row["document_fingerprint"], "vector": vector}
        for row, vector in zip(rows, vectors)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, separators=(",", ":"), sort_keys=True) + "\n")

if __name__ == "__main__": main()
