#!/usr/bin/env python3
import importlib.util
import json
import sys
import tempfile
import os
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Tools/SemanticSearch"))
SPEC = importlib.util.spec_from_file_location(
    "provision", ROOT / "Tools/SemanticSearch/provision_real_encoder.py")
PROVISION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROVISION)


class RealEncoderProvisioningTests(unittest.TestCase):
    def test_frozen_selection_and_contract_are_app_compatible(self):
        lock = json.loads((ROOT / "Tools/SemanticSearch/real-encoder.v1.json").read_text())
        self.assertEqual(lock["sourceRevision"], "c9745ed1d9f207416be6d2e6f8de32d1f16199bf")
        self.assertEqual(len(lock["sourceRevision"]), 40)
        contract = PROVISION.contract_for(lock, "Semantic-caribbean.vocab.json")
        self.assertEqual(contract["embeddingDimension"], 384)
        self.assertEqual(contract["maximumSequenceLength"], 256)
        self.assertEqual(contract["pooling"], "meanMasked")
        self.assertTrue(contract["normalizeL2"])
        self.assertIsNone(contract["tokenTypeIDsFeature"])
        self.assertEqual(contract["modelVersion"], lock["sourceRevision"])

    def test_artifact_stem_follows_the_pack_the_app_searches(self):
        packs = PROVISION.ROOT / "DiveID/Resources/IdentificationPacks"
        lock = json.loads((PROVISION.TOOLS / "real-encoder.v1.json").read_text())
        self.assertEqual(PROVISION.pack_identity(packs / "Caribbean"), ("caribbean", lock["artifactStem"]))
        self.assertEqual(PROVISION.pack_identity(packs / "Global"), ("global", "Semantic-global"))

    def test_sha256_records_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact"
            path.write_bytes(b"Dive-ID\n")
            self.assertEqual(PROVISION.sha256(path),
                             "137642518b0c5d37b89136f0cabf7817b61229990a4ce02387c4dcd71c919cd1")

    def _tree(self, root, entries):
        for name, content in entries:
            path = root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(content)

    def test_directory_digest_is_deterministic_and_nested(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); one = root / "one"; two = root / "two"; one.mkdir(); two.mkdir()
            entries = [("weights/a.bin", b"a"), ("model.mil", b"model")]
            self._tree(one, entries); self._tree(two, reversed(entries))
            os.utime(one / "model.mil", (1, 1)); os.utime(two / "model.mil", (999999, 999999))
            first = PROVISION.compiled_model_fingerprint(one)
            self.assertEqual(first, PROVISION.compiled_model_fingerprint(two))
            self.assertEqual([item["path"] for item in first["files"]], ["model.mil", "weights/a.bin"])

    def test_every_directory_change_changes_digest(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); model = root / "model"; model.mkdir(); self._tree(model, [("a", b"1")])
            original = PROVISION.compiled_model_fingerprint(model)["sha256"]
            (model / "a").write_bytes(b"2")
            changed = PROVISION.compiled_model_fingerprint(model)["sha256"]
            (model / "b").write_bytes(b"3")
            added = PROVISION.compiled_model_fingerprint(model)["sha256"]
            (model / "b").unlink()
            removed = PROVISION.compiled_model_fingerprint(model)["sha256"]
            (model / "a").rename(model / "renamed")
            renamed = PROVISION.compiled_model_fingerprint(model)["sha256"]
            self.assertNotEqual(original, changed)
            self.assertNotEqual(changed, added)
            self.assertNotEqual(added, removed)
            self.assertNotEqual(removed, renamed)

    def test_empty_and_symlink_models_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = Path(temporary) / "model"; model.mkdir()
            with self.assertRaises(ValueError): PROVISION.compiled_model_fingerprint(model)
            target = Path(temporary) / "target"; target.write_text("x"); (model / "link").symlink_to(target)
            with self.assertRaises(ValueError): PROVISION.compiled_model_fingerprint(model)

    def test_mocked_packaging_hashes_destination_and_detects_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); package = root / "source.mlpackage"; package.mkdir()
            (package / "source").write_text("conversion")
            resources = root / "Resources"; extra = root / "contract"; extra.write_text("contract")
            def compiler(_package, output):
                produced = output / "compiler-name.mlmodelc"; produced.mkdir()
                self._tree(produced, [("nested/weights", b"compiled")])
            def evidence(fingerprint):
                return {"schemaVersion": 2, "status": "complete",
                        "completion": {"conversion": True, "compilation": True, "packaging": True},
                        "compiledModel": {"resourceName": "Semantic-caribbean.mlmodelc", **fingerprint}}
            result = PROVISION.package_resources(package, resources, "Semantic-caribbean",
                                                   [(extra, "contract")], evidence, compiler)
            destination = resources / "Semantic-caribbean.mlmodelc"
            self.assertEqual(result["compiledModel"]["sha256"],
                             PROVISION.compiled_model_fingerprint(destination)["sha256"])
            (destination / "nested/weights").write_bytes(b"mutated")
            self.assertNotEqual(result["compiledModel"]["sha256"],
                                PROVISION.compiled_model_fingerprint(destination)["sha256"])

    def test_compiler_or_copy_failure_leaves_previous_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); package = root / "source.mlpackage"; package.mkdir()
            resources = root / "Resources"; resources.mkdir(); (resources / "old").write_text("valid")
            def failed(_package, _output): raise RuntimeError("compiler failure")
            with self.assertRaises(RuntimeError):
                PROVISION.package_resources(package, resources, "Semantic-caribbean", [], lambda _: {}, failed)
            self.assertEqual((resources / "old").read_text(), "valid")
            self.assertFalse((resources / "provisioning-evidence.json").exists())
            def compiler(_package, output):
                produced = output / "model.mlmodelc"; produced.mkdir(); (produced / "data").write_text("x")
            with self.assertRaises(FileNotFoundError):
                PROVISION.package_resources(package, resources, "Semantic-caribbean",
                    [(root / "missing", "missing")], lambda _: {}, compiler)
            self.assertEqual((resources / "old").read_text(), "valid")
            self.assertFalse((resources / "provisioning-evidence.json").exists())

    def test_conversion_environment_is_exactly_pinned_and_hash_locked(self):
        pins = PROVISION.pinned_requirements()
        for name in ("coremltools", "numpy", "torch", "transformers", "tokenizers", "safetensors", "huggingface-hub"):
            self.assertIn(name, pins)
        # coremltools (8.3.0 and 9.0) converts `aten::Int` with int(ndarray), which NumPy 2.4+ rejects.
        major, minor = (int(part) for part in pins["numpy"].split(".")[:2])
        self.assertLess((major, minor), (2, 4))
        lock = (PROVISION.TOOLS / "requirements-real-encoder.txt").read_text()
        locked = {}
        for line in lock.splitlines():
            if line and not line.startswith((" ", "#")):
                name, _, version = line.rstrip(" \\").partition("==")
                locked[name.lower()] = version
        for name, version in pins.items():
            self.assertEqual(locked.get(name), version, f"{name} differs between the .in pins and the lock")
        blocks = [block for block in lock.split("\n") if block and not block.startswith(("#", " "))]
        self.assertTrue(blocks)
        for name in locked:
            self.assertRegex(lock, rf"(?m)^{name}==[^\n]*\\\n\s+--hash=sha256:[0-9a-f]{{64}}")

    def test_unpinned_requirement_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "requirements.in"
            path.write_text("coremltools==8.3.0\nnumpy>=1.14.5\n")
            with self.assertRaises(ValueError):
                PROVISION.pinned_requirements(path)

    def test_environment_drift_is_reported(self):
        pins = {"numpy": "2.3.5", "torch": "2.5.0", "coremltools": "8.3.0"}
        installed = {"numpy": "2.5.4", "torch": "2.5.0+cu124"}.get
        self.assertEqual(PROVISION.environment_mismatches(pins, installed),
                         ["coremltools==8.3.0 (installed: missing)", "numpy==2.3.5 (installed: 2.5.4)"])
        self.assertEqual(PROVISION.environment_mismatches(pins, {**pins, "torch": "2.5.0+cpu"}.get), [])

    def test_parity_fixture_records_encodings_vectors_and_tolerances(self):
        spec = {"tolerances": {"coreMLCosineMinimum": 0.999}, "probes": ["eel"]}
        encodings = [{"input_ids": [101, 102, 0], "attention_mask": [1, 1, 0]}]
        report = {"rows": [{"probe": 0, "referenceTopK": ["a", "b"], "referenceTopKScores": [0.7, 0.5],
                            "referenceTop1Margin": 0.2}]}
        fixture = PROVISION.parity_fixture(spec, "f" * 64, encodings, [[0.6, 0.8]], report)
        self.assertEqual(fixture["probes"], [{"text": "eel", "inputIDs": [101, 102, 0], "attentionMask": [1, 1, 0],
                                              "referenceVector": [0.6, 0.8], "referenceTopK": ["a", "b"],
                                              "referenceTopKScores": [0.7, 0.5], "referenceTop1Margin": 0.2}])
        self.assertEqual(fixture["tolerances"], spec["tolerances"])
        self.assertEqual(fixture["specSHA256"], "f" * 64)

    def test_incomplete_evidence_cannot_claim_compiled_success(self):
        evidence = {"schemaVersion": 2, "status": "incomplete",
                    "completion": {"conversion": True, "compilation": False, "packaging": False},
                    "compiledModel": None}
        self.assertNotEqual(evidence["status"], "complete")
        self.assertFalse(evidence["completion"]["compilation"])


if __name__ == "__main__":
    unittest.main()
