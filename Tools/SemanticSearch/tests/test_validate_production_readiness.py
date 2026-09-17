import copy
import importlib.util
import json
from pathlib import Path
import unittest
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("readiness", ROOT / "Tools/SemanticSearch/validate_production_readiness.py")
MODULE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MODULE)


class ProductionReadinessTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads((ROOT / "Tools/SemanticSearch/production-readiness.v1.json").read_text())

    def test_repository_status_is_valid_and_fail_closed(self):
        errors, approved = MODULE.validate(self.document)
        self.assertEqual(errors, [])
        self.assertFalse(approved)

    def test_exact_identity_change_invalidates_approval(self):
        candidate = copy.deepcopy(self.document)
        candidate["productionStatus"] = "pass"
        candidate["freshDataset"].update(status="available", humanReviewed=True)
        candidate["productionThresholds"] = {"top1": 0.8}
        for engine in candidate["engines"].values(): engine["status"] = "pass"
        candidate["identity"]["compiledModelFingerprint"] = "sha256:test-compiled-model"
        candidate["approval"] = {"status": "approved", "identity": copy.deepcopy(candidate["identity"])}
        self.assertTrue(MODULE.validate(candidate)[1])
        candidate["identity"]["embeddingIndexFingerprint"] = "changed"
        errors, approved = MODULE.validate(candidate)
        self.assertFalse(approved)
        self.assertIn("approval identity mismatch: embeddingIndexFingerprint", errors)

    def test_leaked_dataset_is_rejected(self):
        self.document["freshDataset"]["previousUses"] = ["rankingTuning"]
        errors, _ = MODULE.validate(self.document)
        self.assertIn("fresh dataset has prohibited prior use", errors)

    def test_compiled_evidence_is_verified_and_mutation_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary); model = resources / "Semantic-caribbean.mlmodelc"
            model.mkdir(); (model / "weights").write_bytes(b"compiled")
            fingerprint = MODULE.compiled_model_fingerprint(model)
            evidence = {"schemaVersion": 2, "status": "complete",
                        "completion": {"conversion": True, "compilation": True, "packaging": True},
                        "compiledModel": {"resourceName": model.name, **fingerprint}}
            self.assertEqual(MODULE.validate_provisioning_evidence(evidence, resources), [])
            (model / "weights").write_bytes(b"changed")
            self.assertIn("compiledModel.files mismatch",
                          MODULE.validate_provisioning_evidence(evidence, resources))

    def test_incomplete_provisioning_is_not_runtime_ready(self):
        evidence = {"schemaVersion": 2, "status": "incomplete",
                    "completion": {"conversion": True, "compilation": False, "packaging": False}}
        errors = MODULE.validate_provisioning_evidence(evidence, Path("unused"))
        self.assertIn("compiled-artifact provisioning is incomplete", errors)


if __name__ == "__main__": unittest.main()
