#!/usr/bin/env python3
import copy
import math
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Tools/SemanticSearch"))
import coreml_parity as parity  # noqa: E402
from build_embedding_index import basic_tokens  # noqa: E402


def unit(vector):
    norm = math.sqrt(sum(value * value for value in vector))
    return [value / norm for value in vector]


class CoreMLParityTests(unittest.TestCase):
    def setUp(self):
        self.spec = parity.load_spec()

    def test_tolerances_are_the_frozen_values(self):
        # Changing a tolerance must be a deliberate, reviewed edit here and in the spec.
        self.assertEqual(self.spec["tolerances"], {
            "coreMLCosineMinimum": 0.999, "coreMLMaxAbsoluteDifference": 0.01,
            "unitNormMaxDeviation": 0.0001, "paddingInvarianceCosineMinimum": 0.99999,
            "retrievalTopK": 10, "retrievalTopKOverlapMinimum": 9,
            "retrievalScoreMaxAbsoluteDifference": 0.02,
            "retrievalTop1RequiredWhenReferenceMarginAtLeast": 0.01,
        })

    def test_probes_exercise_truncation_padding_and_punctuation(self):
        lengths = [len(basic_tokens(text, True, True)) for text in self.spec["probes"]]
        self.assertGreater(max(lengths), 254, "one probe must be truncated at 256 tokens")
        self.assertLessEqual(min(lengths), 3, "one probe must be almost all padding")
        self.assertTrue(any(not text.isascii() for text in self.spec["probes"]))

    def test_masked_pooling_reads_only_unmasked_positions(self):
        hidden = [[3.0, 4.0], [1.0, 0.0], [float("nan"), float("inf")], [1e30, -1e30]]
        pooled = parity.masked_mean_normalized(hidden, [1, 1, 0, 0])
        self.assertAlmostEqual(pooled[0], 2.0 / math.sqrt(8.0))
        self.assertAlmostEqual(pooled[1], 2.0 / math.sqrt(8.0))
        self.assertAlmostEqual(math.hypot(*pooled), 1.0)
        with self.assertRaises(ValueError):
            parity.masked_mean_normalized([[float("nan"), 1.0]], [1])
        with self.assertRaises(ValueError):
            parity.masked_mean_normalized([[0.0, 0.0]], [1])
        with self.assertRaises(ValueError):
            parity.masked_mean_normalized([[1.0, 0.0]], [1, 0])

    def _fixture(self, probes=2):
        spec = copy.deepcopy(self.spec); spec["probes"] = spec["probes"][:probes]
        index_ids = [f"species-{number:02d}" for number in range(12)]
        index = [unit([math.cos(number * 0.3), math.sin(number * 0.3), 0.05 * number]) for number in range(12)]
        reference = [unit([1.0, 0.1, 0.2]), unit([0.2, 1.0, 0.1])][:probes]
        return spec, reference, index_ids, index

    def test_identical_vectors_pass(self):
        spec, reference, ids, index = self._fixture()
        report = parity.evaluate(spec, reference, copy.deepcopy(reference), copy.deepcopy(reference), ids, index)
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["summary"]["top1Agreement"], 2)
        self.assertEqual(len(report["rows"][0]["referenceTopK"]), 10)

    def test_small_float16_sized_error_passes(self):
        spec, reference, ids, index = self._fixture()
        coreml = [unit([value + 0.0004 * (-1) ** position for position, value in enumerate(vector)]) for vector in reference]
        report = parity.evaluate(spec, reference, coreml, reference, ids, index)
        self.assertEqual(report["status"], "passed", report["rows"])

    def test_diverging_vector_fails_closed(self):
        spec, reference, ids, index = self._fixture()
        coreml = [reference[0], unit([1.0, 0.1, 0.2])]
        report = parity.evaluate(spec, reference, coreml, reference, ids, index)
        self.assertEqual(report["status"], "failed")
        self.assertIn("cosine", report["rows"][1]["failures"])
        self.assertEqual(report["failedProbes"], 1)

    def test_padding_dependence_fails(self):
        spec, reference, ids, index = self._fixture()
        unpadded = [unit([1.0, 0.12, 0.2]), reference[1]]
        report = parity.evaluate(spec, reference, reference, unpadded, ids, index)
        self.assertIn("padding invariance", report["rows"][0]["failures"])

    def test_non_finite_and_misaligned_inputs_fail(self):
        spec, reference, ids, index = self._fixture()
        report = parity.evaluate(spec, reference, [reference[0], [float("nan")] * 3], reference, ids, index)
        self.assertEqual(report["rows"][1]["failures"], ["non-finite vector"])
        report = parity.evaluate(spec, reference, [reference[0], [1.0, 0.0]], reference, ids, index)
        self.assertEqual(report["rows"][1]["failures"], ["dimension mismatch"])
        with self.assertRaises(ValueError):
            parity.evaluate(spec, reference, reference[:1], reference, ids, index)
        with self.assertRaises(ValueError):
            parity.evaluate(spec, reference, reference, reference, ids[:-1], index)

    def test_retrieval_checks_use_reference_margin_for_top1(self):
        spec, _, _, _ = self._fixture(probes=1)
        spec["tolerances"] = dict(spec["tolerances"], retrievalTopK=2, retrievalTopKOverlapMinimum=2,
                                  coreMLCosineMinimum=0.9, coreMLMaxAbsoluteDifference=1.0,
                                  retrievalScoreMaxAbsoluteDifference=1.0)
        ids = ["a", "b", "c"]
        index = [unit([1.0, 0.0]), unit([0.0, 1.0]), unit([-1.0, -1.0])]
        # A near tie (margin below 0.01) may swap.
        report = parity.evaluate(spec, [unit([1.0, 0.99])], [unit([0.99, 1.0])], [unit([1.0, 0.99])], ids, index)
        self.assertNotIn("top-1", report["rows"][0]["failures"])
        self.assertFalse(report["rows"][0]["top1Matches"])
        # A clear reference winner may not.
        report = parity.evaluate(spec, [unit([1.0, 0.8])], [unit([0.8, 1.0])], [unit([1.0, 0.8])], ids, index)
        self.assertIn("top-1", report["rows"][0]["failures"])


if __name__ == "__main__":
    unittest.main()
