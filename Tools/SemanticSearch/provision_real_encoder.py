#!/usr/bin/env python3
"""Provision the pinned MiniLM encoder, Core ML package, vocabulary, and index.

Nothing fetched by this script is used at app runtime.  Network access is confined to
the explicitly pinned Hugging Face snapshot; the resulting bundle is entirely offline.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from build_embedding_index import (ReferenceWordPieceTokenizer, canonical_json,
                                   tokenizer_fingerprint, vocabulary_checksum)

ROOT = Path(__file__).resolve().parents[2]
TOOLS = Path(__file__).resolve().parent


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(command):
    subprocess.run([str(value) for value in command], cwd=ROOT, check=True)


def contract_for(lock, vocabulary_name):
    revision = lock["sourceRevision"]
    return {
        "contractVersion": 1,
        "modelIdentifier": lock["modelIdentifier"],
        "modelVersion": revision,
        "embeddingDimension": lock["embeddingDimension"],
        "tokenizerIdentifier": f"{lock['modelIdentifier']}@{revision}:WordPiece",
        "preprocessingIdentifier": "minilm-mean-mask-l2-v1",
        "vocabularyFile": vocabulary_name,
        "lowercase": lock["lowercase"], "stripAccents": lock["stripAccents"],
        "maximumSequenceLength": lock["maximumSequenceLength"],
        "truncation": lock["truncation"],
        "clsToken": "[CLS]", "separatorToken": "[SEP]",
        "paddingToken": "[PAD]", "unknownToken": "[UNK]",
        "queryPrefix": lock["queryPrefix"], "documentPrefix": lock["documentPrefix"],
        "inputIDsFeature": "input_ids", "attentionMaskFeature": "attention_mask",
        "tokenTypeIDsFeature": None, "outputFeature": "last_hidden_state",
        "pooling": lock["pooling"], "normalizeL2": lock["normalizeL2"],
    }


def assert_tokenizer_parity(hf, reference):
    # Frozen before parity is inspected: these exercise punctuation, accents, unknowns,
    # WordPiece splitting, whitespace, special tokens, and right truncation.
    cases = [
        "CAFÉ-striped fish near the reef!",
        "diver's blue—green animal; 12cm",
        "juvenile\tang\nwith yellow tail",
        "unaffable bioluminescence ???",
        "reef fish " * 100,
    ]
    for text in cases:
        ours = reference.encode(text)
        expected = hf(text, add_special_tokens=True, padding="max_length", truncation=True,
                      max_length=reference.contract["maximumSequenceLength"],
                      return_attention_mask=True)
        if ours["input_ids"] != expected["input_ids"] or ours["attention_mask"] != expected["attention_mask"]:
            raise RuntimeError(f"Swift-mirror tokenizer differs from pinned tokenizer for {text!r}")


def convert(model_dir, contract, destination):
    import coremltools as ct
    import numpy as np
    import torch
    from transformers import AutoModel

    model = AutoModel.from_pretrained(model_dir, local_files_only=True).eval()

    class Encoder(torch.nn.Module):
        def __init__(self, wrapped):
            super().__init__(); self.wrapped = wrapped

        def forward(self, input_ids, attention_mask):
            return self.wrapped(input_ids=input_ids.long(),
                                attention_mask=attention_mask.long()).last_hidden_state

    length = contract["maximumSequenceLength"]
    sample = (torch.zeros((1, length), dtype=torch.int32), torch.ones((1, length), dtype=torch.int32))
    traced = torch.jit.trace(Encoder(model), sample, strict=True)
    converted = ct.convert(
        traced, convert_to="mlprogram", minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="input_ids", shape=(1, length), dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=(1, length), dtype=np.int32)],
        outputs=[ct.TensorType(name="last_hidden_state")],
    )
    converted.author = "Dive-ID development provisioning"
    converted.license = "Apache-2.0; see bundled THIRD_PARTY_NOTICES.md"
    converted.short_description = f"Pinned {contract['modelIdentifier']} sentence encoder"
    converted.save(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=TOOLS / "generated" / "real-encoder")
    parser.add_argument("--skip-conversion", action="store_true")
    parser.add_argument("--package-resources", type=Path,
                        help="copy app-ready artifacts here; requires macOS coremlcompiler")
    args = parser.parse_args()
    lock_path = TOOLS / "real-encoder.v1.json"
    lock = json.loads(lock_path.read_text())
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)

    try:
        from huggingface_hub import snapshot_download
        from transformers import AutoTokenizer
    except ImportError as error:
        raise SystemExit("Install the pinned requirements-real-encoder.txt first") from error

    model_dir = Path(snapshot_download(
        repo_id=lock["modelIdentifier"], revision=lock["sourceRevision"],
        local_dir=output / "source", allow_patterns=lock["requiredSourceFiles"],
    ))
    missing = [name for name in lock["requiredSourceFiles"] if not (model_dir / name).is_file()]
    if missing:
        raise SystemExit(f"pinned snapshot is incomplete: {missing}")

    vocabulary = {token.rstrip("\n"): offset for offset, token in enumerate(
        (model_dir / "vocab.txt").read_text(encoding="utf-8").splitlines())}
    stem = lock["artifactStem"]
    vocabulary_path = output / f"{stem}.vocab.json"
    vocabulary_path.write_text(canonical_json(vocabulary) + "\n")
    contract = contract_for(lock, vocabulary_path.name)
    # These claims are independently recomputed from the loaded vocabulary by Swift.
    contract["vocabularySHA256"] = vocabulary_checksum(vocabulary)
    contract["tokenizerFingerprint"] = tokenizer_fingerprint(contract, vocabulary)
    contract_path = output / f"{stem}.contract.json"
    contract_path.write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")

    hf = AutoTokenizer.from_pretrained(model_dir, local_files_only=True, use_fast=False)
    hf.truncation_side = "right"
    assert_tokenizer_parity(hf, ReferenceWordPieceTokenizer(vocabulary, contract))

    corpus = output / "caribbean-search-corpus.jsonl"
    index = output / f"{stem}.index.json"
    run([sys.executable, TOOLS / "export_search_corpus.py", "--output", corpus])
    run([sys.executable, TOOLS / "build_embedding_index.py", "--corpus", corpus,
         "--contract", contract_path, "--model", model_dir, "--output", index])

    package = output / f"{stem}.mlpackage"
    if not args.skip_conversion:
        convert(model_dir, contract, package)

    license_path = TOOLS / "licenses" / "Apache-2.0.txt"
    files = [lock_path, license_path, *[model_dir / name for name in lock["requiredSourceFiles"]],
             vocabulary_path, contract_path, corpus, index]
    if package.exists():
        files.extend(path for path in package.rglob("*") if path.is_file())
    evidence = {
        "schemaVersion": 1, "createdAtUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sourceRevision": lock["sourceRevision"], "modelIdentifier": lock["modelIdentifier"],
        "environment": {"platform": platform.platform(), "python": platform.python_version()},
        "tokenizerParityCases": 5,
        "artifacts": [{"path": str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path),
                       "bytes": path.stat().st_size, "sha256": sha256(path)} for path in files],
    }
    evidence_path = output / "provisioning-evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")

    if args.package_resources:
        if not package.exists(): raise SystemExit("packaging requires conversion")
        if sys.platform != "darwin" or not shutil.which("xcrun"):
            raise SystemExit("packaging .mlmodelc requires macOS with Xcode (xcrun coremlcompiler)")
        target = args.package_resources.resolve(); target.mkdir(parents=True, exist_ok=True)
        compiled_parent = output / "compiled"; shutil.rmtree(compiled_parent, ignore_errors=True)
        run(["xcrun", "coremlcompiler", "compile", package, compiled_parent])
        produced = next(compiled_parent.glob("*.mlmodelc"))
        shutil.copytree(produced, target / f"{stem}.mlmodelc", dirs_exist_ok=True)
        for path in (contract_path, vocabulary_path, index, evidence_path): shutil.copy2(path, target / path.name)
        notice = target / "THIRD_PARTY_NOTICES.md"
        notice.write_text("# Third-party notices\n\nThe bundled `sentence-transformers/all-MiniLM-L6-v2` "
                          f"weights and tokenizer at `{lock['sourceRevision']}` are licensed under Apache-2.0. "
                          "The complete license is included as `MiniLM-LICENSE.txt`.\n")
        shutil.copy2(license_path, target / "MiniLM-LICENSE.txt")
    print(evidence_path)


if __name__ == "__main__":
    main()
