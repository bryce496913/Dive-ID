#!/usr/bin/env python3
import importlib.util
import json
import sys
import tempfile
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


if __name__ == "__main__":
    unittest.main()
