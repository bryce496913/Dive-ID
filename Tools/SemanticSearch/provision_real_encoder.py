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
import tempfile
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


def compiled_model_fingerprint(directory):
    """Return a deterministic, strict fingerprint of a compiled model directory.

    The aggregate is SHA-256 over canonical JSON (UTF-8, no trailing newline) of the
    ordered per-file records. Symlinks and non-regular entries are rejected rather
    than followed or silently omitted.
    """
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError(f"compiled model is not a real directory: {directory}")
    records = []
    for path in sorted(directory.rglob("*"), key=lambda item: item.relative_to(directory).as_posix()):
        relative = path.relative_to(directory).as_posix()
        if path.is_symlink():
            raise ValueError(f"compiled model contains symlink: {relative}")
        if path.is_dir():
            continue
        if not path.is_file():
            raise ValueError(f"compiled model contains unsupported entry: {relative}")
        records.append({"path": relative, "bytes": path.stat().st_size, "sha256": sha256(path)})
    if not records:
        raise ValueError("compiled model contains no regular files")
    serialized = json.dumps(records, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return {"algorithm": "sha256-canonical-file-manifest-v1", "files": records,
            "sha256": hashlib.sha256(serialized.encode("utf-8")).hexdigest()}


def atomic_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)


def tool_version(command):
    try:
        result = subprocess.run(command, check=True, text=True, capture_output=True)
        return (result.stdout or result.stderr).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


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


def package_resources(package, resources, stem, copy_files, evidence_builder,
                      compiler=None):
    """Compile and transactionally install resources, then write success evidence.

    ``compiler`` is injectable solely for unit tests; normal provisioning invokes
    xcrun coremlcompiler. The fingerprint is always calculated after copying into
    the staged *final resource layout*, never from compiler output.
    """
    resources = Path(resources).resolve()
    resources.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="diveid-package-", dir=resources.parent) as work_name:
        work = Path(work_name)
        compiled_parent = work / "compiler-output"
        compiled_parent.mkdir()
        if compiler:
            compiler(package, compiled_parent)
        else:
            run(["xcrun", "coremlcompiler", "compile", package, compiled_parent])
        produced = list(compiled_parent.glob("*.mlmodelc"))
        if len(produced) != 1:
            raise RuntimeError(f"compiler produced {len(produced)} .mlmodelc directories; expected one")
        # Validate compiler output first, including symlinks/unsupported entries.
        compiled_model_fingerprint(produced[0])

        staged = work / "resources"
        if resources.exists():
            if not resources.is_dir() or resources.is_symlink():
                raise RuntimeError(f"resource destination is not a real directory: {resources}")
            shutil.copytree(resources, staged)
        else:
            staged.mkdir()
        final_model = staged / f"{stem}.mlmodelc"
        if final_model.is_symlink() or (final_model.exists() and not final_model.is_dir()):
            final_model.unlink()
        elif final_model.exists():
            shutil.rmtree(final_model)
        shutil.copytree(produced[0], final_model)
        for source, destination_name in copy_files:
            shutil.copy2(source, staged / destination_name)
        fingerprint = compiled_model_fingerprint(final_model)
        evidence = evidence_builder(fingerprint)
        atomic_json(staged / "provisioning-evidence.json", evidence)

        backup = work / "previous-resources"
        if resources.exists():
            os.replace(resources, backup)
        try:
            os.replace(staged, resources)
        except BaseException:
            if backup.exists():
                os.replace(backup, resources)
            raise
        return evidence


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
    base_evidence = {
        "schemaVersion": 2, "createdAtUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sourceRevision": lock["sourceRevision"], "modelIdentifier": lock["modelIdentifier"],
        "environment": {"platform": platform.platform(), "python": platform.python_version(),
                        "xcodebuild": tool_version(["xcodebuild", "-version"]),
                        "coremlcompiler": tool_version(["xcrun", "coremlcompiler", "--version"])},
        "tokenizerParityCases": 5,
        "artifacts": [{"path": str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path),
                       "bytes": path.stat().st_size, "sha256": sha256(path)} for path in files],
        "identities": {"sourceModel": f"{lock['modelIdentifier']}@{lock['sourceRevision']}",
                       "tokenizerFingerprint": contract["tokenizerFingerprint"],
                       "contractSHA256": sha256(contract_path), "corpusSHA256": sha256(corpus),
                       "indexSHA256": sha256(index)},
    }
    evidence_path = output / "provisioning-evidence.json"
    if args.package_resources:
        if not package.exists(): raise SystemExit("packaging requires conversion")
        if sys.platform != "darwin" or not shutil.which("xcrun"):
            incomplete = dict(base_evidence, status="incomplete",
                              completion={"conversion": package.exists(), "compilation": False,
                                          "packaging": False}, compiledModel=None)
            atomic_json(evidence_path, incomplete)
            raise SystemExit("packaging .mlmodelc requires macOS with Xcode (xcrun coremlcompiler); incomplete evidence written")
        notice = output / "THIRD_PARTY_NOTICES.md"
        notice.write_text("# Third-party notices\n\nThe bundled `sentence-transformers/all-MiniLM-L6-v2` "
                          f"weights and tokenizer at `{lock['sourceRevision']}` are licensed under Apache-2.0. "
                          "The complete license is included as `MiniLM-LICENSE.txt`.\n")
        def successful(fingerprint):
            return dict(base_evidence, status="complete",
                        completion={"conversion": True, "compilation": True, "packaging": True},
                        compiledModel={"resourceName": f"{stem}.mlmodelc", **fingerprint,
                                       "sourcePackage": compiled_model_fingerprint(package)})
        evidence = package_resources(package, args.package_resources, stem,
            [(contract_path, contract_path.name), (vocabulary_path, vocabulary_path.name),
             (index, index.name), (notice, notice.name), (license_path, "MiniLM-LICENSE.txt")], successful)
        atomic_json(evidence_path, evidence)
    else:
        evidence = dict(base_evidence, status="incomplete",
                        completion={"conversion": package.exists(), "compilation": False, "packaging": False},
                        compiledModel=None)
        atomic_json(evidence_path, evidence)
    print(evidence_path)


if __name__ == "__main__":
    main()
