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

    def test_incomplete_evidence_cannot_claim_compiled_success(self):
        evidence = {"schemaVersion": 2, "status": "incomplete",
                    "completion": {"conversion": True, "compilation": False, "packaging": False},
                    "compiledModel": None}
        self.assertNotEqual(evidence["status"], "complete")
        self.assertFalse(evidence["completion"]["compilation"])


if __name__ == "__main__":
    unittest.main()
