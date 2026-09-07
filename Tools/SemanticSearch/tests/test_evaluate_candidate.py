import copy
import hashlib
import importlib.util
import math
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).parents[1] / "evaluate_candidate.py"
spec = importlib.util.spec_from_file_location("evaluate_candidate", MODULE)
evaluation = importlib.util.module_from_spec(spec); spec.loader.exec_module(evaluation)
SHA = "a" * 64


def valid_manifest():
    return {
        "schemaVersion": 1, "frozenAtUTC": "2026-01-01T00:00:00Z",
        "model": {"source": "https://example.invalid/model", "revision": "abcdef1234567890", "license": "Apache-2.0", "identifier": "model", "version": "1.0"},
        "conversion": {"tool": "coremltools", "toolVersion": "8.0", "sourceFormat": "PyTorch 2.5", "coreMLFormat": "mlprogram", "minimumDeploymentTarget": "iOS18", "computePrecision": "float16", "expectedInputs": [{"name": "input_ids", "dataType": "int32", "shape": [1, 128]}], "expectedOutputs": [{"name": "hidden", "dataType": "float16", "shape": [1, 128, 384]}]},
        "preprocessing": {"tokenizerIdentifier": "wordpiece-v1", "tokenizerRevision": "abcdef1234567890", "vocabularySHA256": SHA, "lowercase": True, "stripAccents": True, "maximumSequenceLength": 128, "truncation": "end", "specialTokens": {"cls": "[CLS]", "separator": "[SEP]", "padding": "[PAD]", "unknown": "[UNK]"}, "prefixes": {"query": "query: ", "document": "passage: "}, "pooling": "meanMasked", "normalization": "l2"},
        "ranking": {"contractVersion": 1, "candidateLimit": 50, "parameters": {"ranker": "LocalSpeciesRanker.v1"}},
        "acceptanceCriteria": {"benchmarkGateVersion": 1, "numericalParity": {"maximumAbsoluteError": 0.001, "minimumCosineSimilarity": 0.999, "maximumTop10RankingChanges": 0}},
        "catalogue": {"packID": "caribbean", "packVersion": 3, "speciesCount": 8, "searchDocumentSchemaVersion": 1, "fingerprint": SHA},
        "datasets": [{"identifier": "development-v1", "fingerprint": SHA, "role": "development"}],
        "artifacts": [{"path": "model.bin", "sha256": SHA, "role": "converted-model"}],
    }


class CandidateEvaluationTests(unittest.TestCase):
    def test_parity_reports_ranking_change_and_enforces_tolerances(self):
        reference = [{"id": "q", "vector": [1.0, 0.0]}]
        converted = [{"id": "q", "vector": [0.0, 1.0]}]
        catalogue = [{"id": "a", "vector": [1.0, 0.0]}, {"id": "b", "vector": [0.0, 1.0]}]
        result = evaluation.parity(reference, converted, catalogue,
            {"maximumAbsoluteError": 0.01, "minimumCosineSimilarity": 0.99, "maximumTop10RankingChanges": 0})
        self.assertEqual(result["status"], "fail"); self.assertEqual(result["top10RankingChanges"], 1)

    def test_complete_manifest_and_checksum_are_verified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); artifact = root / "model.bin"; artifact.write_bytes(b"genuine bytes")
            manifest = valid_manifest(); manifest["artifacts"][0]["sha256"] = hashlib.sha256(b"genuine bytes").hexdigest()
            evaluation.validate_manifest(manifest)
            self.assertEqual(evaluation.verify_files(manifest, root), [])
            artifact.write_bytes(b"changed")
            self.assertIn("checksum mismatch: model.bin", evaluation.verify_files(manifest, root))

    def assert_invalid(self, mutate):
        manifest = valid_manifest(); mutate(manifest)
        with self.assertRaises(ValueError): evaluation.validate_manifest(manifest)

    def test_rejects_empty_or_missing_top_level_evidence_sections(self):
        for section in ("model", "conversion", "preprocessing", "ranking", "acceptanceCriteria", "catalogue"):
            with self.subTest(section=section): self.assert_invalid(lambda value, section=section: value.__setitem__(section, {}))
        self.assert_invalid(lambda value: value.__setitem__("datasets", {}))
        self.assert_invalid(lambda value: value.__setitem__("artifacts", []))

    def test_rejects_invalid_frozen_timestamp(self):
        for timestamp in ("", "2026-01-01", "2026-01-01T00:00:00+00:00", "2026-99-01T00:00:00Z"):
            with self.subTest(timestamp=timestamp): self.assert_invalid(lambda value, timestamp=timestamp: value.__setitem__("frozenAtUTC", timestamp))

    def test_rejects_unpinned_or_incomplete_model(self):
        for field in ("source", "revision", "identifier", "license", "version"):
            with self.subTest(field=field): self.assert_invalid(lambda value, field=field: value["model"].pop(field))
        for revision in ("main", "latest", "abc"):
            self.assert_invalid(lambda value, revision=revision: value["model"].__setitem__("revision", revision))

    def test_rejects_incomplete_conversion_and_feature_declarations(self):
        for field in ("tool", "toolVersion", "sourceFormat", "coreMLFormat", "minimumDeploymentTarget", "computePrecision", "expectedInputs", "expectedOutputs"):
            with self.subTest(field=field): self.assert_invalid(lambda value, field=field: value["conversion"].pop(field))
        self.assert_invalid(lambda value: value["conversion"].__setitem__("expectedInputs", []))
        self.assert_invalid(lambda value: value["conversion"]["expectedOutputs"][0].pop("shape"))

    def test_rejects_incomplete_preprocessing(self):
        fields = ("tokenizerIdentifier", "tokenizerRevision", "vocabularySHA256", "lowercase", "stripAccents", "maximumSequenceLength", "truncation", "specialTokens", "prefixes", "pooling", "normalization")
        for field in fields:
            with self.subTest(field=field): self.assert_invalid(lambda value, field=field: value["preprocessing"].pop(field))
        self.assert_invalid(lambda value: value["preprocessing"].__setitem__("vocabularySHA256", "bad"))
        self.assert_invalid(lambda value: value["preprocessing"]["specialTokens"].pop("unknown"))
        self.assert_invalid(lambda value: value["preprocessing"]["prefixes"].pop("document"))

    def test_rejects_incomplete_ranking_and_numerical_gates(self):
        for field in ("contractVersion", "candidateLimit", "parameters"):
            with self.subTest(field=field): self.assert_invalid(lambda value, field=field: value["ranking"].pop(field))
        for field in ("maximumAbsoluteError", "minimumCosineSimilarity", "maximumTop10RankingChanges"):
            with self.subTest(field=field): self.assert_invalid(lambda value, field=field: value["acceptanceCriteria"]["numericalParity"].pop(field))
        for invalid in (None, math.nan, math.inf, -1):
            self.assert_invalid(lambda value, invalid=invalid: value["acceptanceCriteria"]["numericalParity"].__setitem__("maximumAbsoluteError", invalid))
        self.assert_invalid(lambda value: value["acceptanceCriteria"]["numericalParity"].__setitem__("maximumTop10RankingChanges", -1))

    def test_rejects_incomplete_catalogue_and_datasets(self):
        for field in ("packID", "packVersion", "speciesCount", "searchDocumentSchemaVersion", "fingerprint"):
            with self.subTest(field=field): self.assert_invalid(lambda value, field=field: value["catalogue"].pop(field))
        self.assert_invalid(lambda value: value.__setitem__("datasets", []))
        for field in ("identifier", "fingerprint", "role"):
            self.assert_invalid(lambda value, field=field: value["datasets"][0].pop(field))

    def test_rejects_incomplete_duplicate_or_malformed_artifacts(self):
        for field in ("path", "sha256", "role"):
            self.assert_invalid(lambda value, field=field: value["artifacts"][0].pop(field))
        self.assert_invalid(lambda value: value["artifacts"][0].__setitem__("sha256", "bad"))
        self.assert_invalid(lambda value: value["artifacts"].append(copy.deepcopy(value["artifacts"][0])))


if __name__ == "__main__": unittest.main()
