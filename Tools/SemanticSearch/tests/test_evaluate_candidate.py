import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).parents[1] / "evaluate_candidate.py"
spec = importlib.util.spec_from_file_location("evaluate_candidate", MODULE)
evaluation = importlib.util.module_from_spec(spec); spec.loader.exec_module(evaluation)


class CandidateEvaluationTests(unittest.TestCase):
    def test_parity_reports_ranking_change_and_enforces_tolerances(self):
        reference = [{"id": "q", "vector": [1.0, 0.0]}]
        converted = [{"id": "q", "vector": [0.0, 1.0]}]
        catalogue = [{"id": "a", "vector": [1.0, 0.0]}, {"id": "b", "vector": [0.0, 1.0]}]
        result = evaluation.parity(reference, converted, catalogue,
            {"maximumAbsoluteError": 0.01, "minimumCosineSimilarity": 0.99, "maximumTop10RankingChanges": 0})
        self.assertEqual(result["status"], "fail")
        self.assertEqual(result["top10RankingChanges"], 1)

    def test_manifest_checksum_is_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); artifact = root / "model.bin"; artifact.write_bytes(b"genuine bytes")
            manifest = {"schemaVersion": 1, "frozenAtUTC": "2026-01-01T00:00:00Z",
                "model": {"source": "https://example.invalid", "revision": "abc", "license": "Apache-2.0", "identifier": "model"},
                "conversion": {}, "preprocessing": {}, "ranking": {}, "acceptanceCriteria": {}, "catalogue": {}, "datasets": {},
                "artifacts": [{"path": "model.bin", "sha256": hashlib.sha256(b"genuine bytes").hexdigest()}]}
            evaluation.validate_manifest(manifest)
            self.assertEqual(evaluation.verify_files(manifest, root), [])
            artifact.write_bytes(b"changed")
            self.assertIn("checksum mismatch: model.bin", evaluation.verify_files(manifest, root))


if __name__ == "__main__": unittest.main()
