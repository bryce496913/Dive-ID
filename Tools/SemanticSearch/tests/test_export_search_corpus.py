import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "export_search_corpus.py"
SPEC = importlib.util.spec_from_file_location("export_search_corpus", MODULE_PATH)
exporter = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(exporter)

class CorpusExporterTests(unittest.TestCase):
    fixture = Path(__file__).parent / "fixtures"

    def export(self, directory=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name) / "corpus.jsonl"
        exporter.export_pack(directory or self.fixture, output)
        return output.read_bytes()

    def test_repeated_exports_are_byte_identical_and_ids_are_exact(self):
        first = self.export()
        second = self.export()
        self.assertEqual(first, second)
        row = json.loads(first)
        self.assertEqual(row["species_id"], "00000000-0000-0000-0000-000000000003")
        self.assertEqual(row["pack_id"], "fixture-pack")
        self.assertEqual(row["pack_version"], 7)

    def test_search_text_uses_only_canonical_document_evidence(self):
        source = json.loads((self.fixture / "Creatures.json").read_text())[0]
        document = exporter.build_search_document(source)
        row = json.loads(self.export())
        self.assertEqual(row["search_text"], document["combined"])
        self.assertEqual(row["document_fingerprint"], document["fingerprint"])
        self.assertIn("yellow juvenile", row["search_text"])
        self.assertNotIn("ocean", row["search_text"])

    def test_review_state_is_preserved_without_promotion(self):
        source_review = json.loads((self.fixture / "Creatures.json").read_text())[0]["review"]
        row = json.loads(self.export())
        self.assertEqual(row["review"], source_review)
        self.assertEqual(row["review_status"], "draft")
        self.assertEqual(row["provenance_tier"], "draft")
        self.assertTrue(row["human_review_required"])

    def test_invalid_records_are_reported_not_repaired(self):
        with tempfile.TemporaryDirectory() as directory:
            pack = Path(directory)
            (pack / "PackManifest.json").write_text('{"id":"x","packVersion":1,"speciesCount":1,"speciesResourceName":"Creatures"}')
            (pack / "Creatures.json").write_text('[{"id":"unchanged"}]')
            with self.assertRaisesRegex(exporter.ExportValidationError, r"record 0: commonName"):
                exporter.export_pack(pack, pack / "output.jsonl")
            self.assertFalse((pack / "output.jsonl").exists())

    def test_benchmark_holdout_cannot_be_mistaken_for_catalogue_input(self):
        benchmark = Path("DiveIDTests/Fixtures/CaribbeanIdentificationBenchmark.json")
        rows = json.loads(benchmark.read_text())
        self.assertEqual(sum(row["split"] == "holdout" for row in rows), 30)
        with tempfile.TemporaryDirectory() as directory:
            pack = Path(directory)
            (pack / "PackManifest.json").write_text(json.dumps({"id":"x","packVersion":1,"speciesCount":len(rows),"speciesResourceName":"Creatures"}))
            (pack / "Creatures.json").write_text(json.dumps(rows))
            with self.assertRaises(exporter.ExportValidationError):
                exporter.export_pack(pack, pack / "output.jsonl")
            self.assertFalse((pack / "output.jsonl").exists())

if __name__ == "__main__":
    unittest.main()
