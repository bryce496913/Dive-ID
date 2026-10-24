#!/usr/bin/env python3
"""Provision the pinned MiniLM encoder, Core ML package, vocabulary, and index.

Nothing fetched by this script is used at app runtime.  Network access is confined to
the explicitly pinned Hugging Face snapshot; the resulting bundle is entirely offline.
"""
import argparse
import hashlib
import json
import math
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
REQUIREMENTS = TOOLS / "requirements-real-encoder.in"
EVIDENCE_SCHEMA_VERSION = 3


def pinned_requirements(path=REQUIREMENTS):
    """The direct ``name==version`` pins of the conversion environment."""
    pins = {}
    for line in Path(path).read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        name, separator, version = line.partition("==")
        if not separator or not version.strip():
            raise ValueError(f"conversion requirement is not pinned exactly: {line}")
        pins[name.strip().lower()] = version.strip()
    return pins


def environment_mismatches(pins, installed_version):
    """Pins whose installed version differs (``installed_version`` returns None when absent)."""
    mismatches = []
    for name, version in sorted(pins.items()):
        installed = installed_version(name)
        if installed is None or installed.split("+", 1)[0] != version:
            mismatches.append(f"{name}=={version} (installed: {installed or 'missing'})")
    return mismatches


def verify_pinned_environment():
    """Fail before downloading or converting when the environment drifted from the pins:
    an unpinned NumPy 2.5 broke conversion once (see requirements-real-encoder.in)."""
    from importlib import metadata

    def installed(name):
        try:
            return metadata.version(name)
        except metadata.PackageNotFoundError:
            return None
    mismatches = environment_mismatches(pinned_requirements(), installed)
    if mismatches:
        raise SystemExit("conversion environment differs from requirements-real-encoder.in; install "
                         "requirements-real-encoder.txt with --require-hashes: " + ", ".join(mismatches))
    return {name: installed(name) for name in sorted(pinned_requirements())}


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


def pack_identity(pack_directory):
    """Return the pack ID and the ``Semantic-<pack>`` stem the app looks up for it."""
    manifest = json.loads((Path(pack_directory) / "PackManifest.json").read_text(encoding="utf-8"))
    return manifest["id"], f"Semantic-{manifest['id']}"


def contract_for(lock, vocabulary_name):
    revision = lock["sourceRevision"]
    return {
        "contractVersion": 1,
        "modelIdentifier": lock["modelIdentifier"],
        "modelVersion": revision,
        "embeddingDimension": lock["embeddingDimension"],
        "tokenizerIdentifier": f"{lock['modelIdentifier']}@{revision}:BertWordPiece",
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


# Frozen before parity is inspected: these exercise punctuation, accents, unknowns,
# WordPiece splitting, whitespace, special tokens, and right truncation.
TOKENIZER_PARITY_CASES = [
    "CAFÉ-striped fish near the reef!",
    "diver's blue—green animal; 12cm",
    "juvenile\tang\nwith yellow tail",
    "unaffable bioluminescence ???",
    "reef fish " * 100,
]


def assert_tokenizer_parity(hf, reference, cases=TOKENIZER_PARITY_CASES):
    """Check the Swift mirror's IDs and masks (padding and truncation included) against the
    pinned tokenizer; returns the pinned tokenizer's encodings."""
    encodings = []
    for text in cases:
        ours = reference.encode(text)
        expected = hf(text, add_special_tokens=True, padding="max_length", truncation=True,
                      max_length=reference.contract["maximumSequenceLength"],
                      return_attention_mask=True)
        if ours["input_ids"] != expected["input_ids"] or ours["attention_mask"] != expected["attention_mask"]:
            raise RuntimeError(f"Swift-mirror tokenizer differs from pinned tokenizer for {text!r}")
        encodings.append({"input_ids": list(expected["input_ids"]), "attention_mask": list(expected["attention_mask"])})
    return encodings


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
    traced = torch.jit.trace(Encoder(model).eval(), sample, strict=True)
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


def reference_vectors(model_dir, encodings):
    """Float32 PyTorch vectors for each encoding, padded (as the index is built) and with
    the padding removed (to prove the attention mask makes padding irrelevant)."""
    import torch
    from transformers import AutoModel
    from coreml_parity import masked_mean_normalized

    model = AutoModel.from_pretrained(model_dir, local_files_only=True).eval()
    padded, unpadded = [], []
    with torch.inference_mode():
        for encoding in encodings:
            ids = torch.tensor([encoding["input_ids"]], dtype=torch.long)
            mask = torch.tensor([encoding["attention_mask"]], dtype=torch.long)
            hidden = model(input_ids=ids, attention_mask=mask).last_hidden_state[0].float().numpy()
            padded.append(masked_mean_normalized(hidden, encoding["attention_mask"]))
            length = sum(encoding["attention_mask"])
            hidden = model(input_ids=ids[:, :length], attention_mask=mask[:, :length]).last_hidden_state[0].float().numpy()
            unpadded.append(masked_mean_normalized(hidden, [1] * length))
    return padded, unpadded


def coreml_vectors(package, encodings, contract):
    """Vectors from the converted package through Core ML (macOS only), pooled as the app pools."""
    import coremltools as ct
    import numpy as np
    from coreml_parity import masked_mean_normalized

    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.ALL)
    vectors = []
    for encoding in encodings:
        output = model.predict({
            contract["inputIDsFeature"]: np.asarray([encoding["input_ids"]], dtype=np.int32),
            contract["attentionMaskFeature"]: np.asarray([encoding["attention_mask"]], dtype=np.int32),
        })[contract["outputFeature"]]
        vectors.append(masked_mean_normalized(np.asarray(output)[0], encoding["attention_mask"]))
    return vectors


def _finite_or_none(value):
    return value if isinstance(value, (int, float)) and math.isfinite(value) else None


def parity_fixture(spec, spec_sha256, encodings, reference, report):
    """What the Swift test re-checks in the app: the pinned tokenizer's encodings and the
    reference vectors for each frozen probe, with the frozen tolerances."""
    rows = {row["probe"]: row for row in report["rows"]}
    return {"schemaVersion": 1, "specSHA256": spec_sha256, "tolerances": spec["tolerances"],
            "probes": [{"text": text, "inputIDs": encoding["input_ids"], "attentionMask": encoding["attention_mask"],
                        "referenceVector": [float(str(value)) for value in vector],
                        "referenceTopK": rows[position].get("referenceTopK", []),
                        "referenceTopKScores": rows[position].get("referenceTopKScores", []),
                        # JSON has no infinity: a one-record index has no runner-up, so no margin.
                        "referenceTop1Margin": _finite_or_none(rows[position].get("referenceTop1Margin"))}
                       for position, (text, encoding, vector) in enumerate(zip(spec["probes"], encodings, reference))]}


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
    parser.add_argument("--pack", type=Path, default=ROOT / "DiveID/Resources/IdentificationPacks/Caribbean",
                        help="identification pack to index; the app looks up Semantic-<pack id>.*")
    parser.add_argument("--skip-conversion", action="store_true")
    parser.add_argument("--package-resources", type=Path,
                        help="copy app-ready artifacts here; requires macOS coremlcompiler")
    args = parser.parse_args()
    lock_path = TOOLS / "real-encoder.v1.json"
    lock = json.loads(lock_path.read_text())
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    packages = verify_pinned_environment()

    try:
        from huggingface_hub import snapshot_download
        from transformers import AutoTokenizer
    except ImportError as error:
        raise SystemExit("Install the pinned requirements-real-encoder.txt first") from error
    from coreml_parity import SPEC_PATH, evaluate, load_spec

    parity_spec = load_spec()
    parity_spec_sha256 = sha256(SPEC_PATH)
    model_dir = Path(snapshot_download(
        repo_id=lock["modelIdentifier"], revision=lock["sourceRevision"],
        local_dir=output / "source", allow_patterns=lock["requiredSourceFiles"],
    ))
    missing = [name for name in lock["requiredSourceFiles"] if not (model_dir / name).is_file()]
    if missing:
        raise SystemExit(f"pinned snapshot is incomplete: {missing}")

    vocabulary = {token.rstrip("\n"): offset for offset, token in enumerate(
        (model_dir / "vocab.txt").read_text(encoding="utf-8").splitlines())}
    pack_id, stem = pack_identity(args.pack)
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
    reference_tokenizer = ReferenceWordPieceTokenizer(vocabulary, contract)
    assert_tokenizer_parity(hf, reference_tokenizer)
    probe_encodings = assert_tokenizer_parity(hf, reference_tokenizer, parity_spec["probes"])

    # Convert before the (long) index build, so a conversion failure surfaces in seconds.
    package = output / f"{stem}.mlpackage"
    if not args.skip_conversion:
        convert(model_dir, contract, package)

    corpus = output / f"{pack_id}-search-corpus.jsonl"
    index = output / f"{stem}.index.json"
    run([sys.executable, TOOLS / "export_search_corpus.py", "--pack", args.pack.resolve(), "--output", corpus])
    run([sys.executable, TOOLS / "build_embedding_index.py", "--corpus", corpus,
         "--contract", contract_path, "--model", model_dir, "--output", index])

    # Numerical parity against the frozen tolerances; Core ML predictions need macOS.
    parity_path = output / f"{stem}.parity.json"
    if not package.exists():
        parity = {"status": "not run", "reason": "no converted package"}
    elif sys.platform != "darwin":
        parity = {"status": "not run", "reason": "Core ML predictions require macOS"}
    else:
        reference, unpadded = reference_vectors(model_dir, probe_encodings)
        coreml = coreml_vectors(package, probe_encodings, contract)
        records = json.loads(index.read_text())["records"]
        report = evaluate(parity_spec, reference, coreml, unpadded,
                          [record["speciesID"] for record in records], [record["vector"] for record in records])
        atomic_json(parity_path, parity_fixture(parity_spec, parity_spec_sha256, probe_encodings, reference, report))
        parity = {"status": report["status"], "specSHA256": parity_spec_sha256, "computeUnits": "ALL",
                  "fixture": {"resourceName": parity_path.name, "sha256": sha256(parity_path)}, "report": report}
        print(f"Core ML parity {report['status']}: " + json.dumps(report["summary"], sort_keys=True))

    license_path = TOOLS / "licenses" / "Apache-2.0.txt"
    files = [lock_path, license_path, SPEC_PATH, *[model_dir / name for name in lock["requiredSourceFiles"]],
             vocabulary_path, contract_path, corpus, index]
    if parity_path.exists():
        files.append(parity_path)
    if package.exists():
        files.extend(path for path in package.rglob("*") if path.is_file())
    base_evidence = {
        "schemaVersion": EVIDENCE_SCHEMA_VERSION, "createdAtUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "sourceRevision": lock["sourceRevision"], "modelIdentifier": lock["modelIdentifier"],
        "environment": {"platform": platform.platform(), "macOS": platform.mac_ver()[0] or None,
                        "python": platform.python_version(), "packages": packages,
                        "xcodebuild": tool_version(["xcodebuild", "-version"]),
                        "coremlcompiler": tool_version(["xcrun", "coremlcompiler", "--version"])},
        "tokenizerParityCases": len(TOKENIZER_PARITY_CASES) + len(parity_spec["probes"]),
        "parity": parity,
        "artifacts": [{"path": str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path),
                       "bytes": path.stat().st_size, "sha256": sha256(path)} for path in files],
        "identities": {"sourceModel": f"{lock['modelIdentifier']}@{lock['sourceRevision']}",
                       "tokenizerFingerprint": contract["tokenizerFingerprint"],
                       "vocabularySHA256": contract["vocabularySHA256"],
                       "contractSHA256": sha256(contract_path), "corpusSHA256": sha256(corpus),
                       "indexSHA256": sha256(index)},
    }
    evidence_path = output / "provisioning-evidence.json"

    def incomplete(compilation=False):
        return dict(base_evidence, status="incomplete",
                    completion={"conversion": package.exists(), "compilation": compilation, "packaging": False},
                    compiledModel=None)
    if parity["status"] == "failed":
        atomic_json(evidence_path, incomplete())
        raise SystemExit(f"Core ML vectors are outside the frozen parity tolerances; see {evidence_path}")
    if args.package_resources:
        if not package.exists(): raise SystemExit("packaging requires conversion")
        if sys.platform != "darwin" or not shutil.which("xcrun"):
            atomic_json(evidence_path, incomplete())
            raise SystemExit("packaging .mlmodelc requires macOS with Xcode (xcrun coremlcompiler); incomplete evidence written")
        if parity["status"] != "passed":
            atomic_json(evidence_path, incomplete())
            raise SystemExit(f"packaging requires passing Core ML parity ({parity['status']})")
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
             (index, index.name), (parity_path, parity_path.name), (notice, notice.name),
             (license_path, "MiniLM-LICENSE.txt")], successful)
        atomic_json(evidence_path, evidence)
    else:
        atomic_json(evidence_path, incomplete())
    print(evidence_path)


if __name__ == "__main__":
    main()
