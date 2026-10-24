#!/usr/bin/env python3
"""Real coremltools conversion of the encoder graph provisioning converts.

The model has all-MiniLM-L6-v2's exact architecture (config of the pinned revision) with
seeded random weights, so the traced graph is the one that failed in CI without downloading
weights. It runs `provision_real_encoder.convert` itself, not a mock. Skipped when the
conversion tooling is not installed, unless DIVEID_REQUIRE_CONVERSION=1 (the semantic-search
workflow), where a skip would hide exactly the failure this guards against.

    python3 -m unittest Tools/SemanticSearch/tests/test_coreml_conversion.py
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "Tools/SemanticSearch"))

try:
    import coremltools  # noqa: F401
    import numpy  # noqa: F401
    import torch
    import transformers  # noqa: F401
    AVAILABLE = True
except ImportError:
    AVAILABLE = False
REQUIRED = os.environ.get("DIVEID_REQUIRE_CONVERSION") == "1"

# config.json of sentence-transformers/all-MiniLM-L6-v2 at the pinned revision.
MINILM_CONFIG = dict(vocab_size=30522, hidden_size=384, num_hidden_layers=6, num_attention_heads=12,
                     intermediate_size=1536, hidden_act="gelu", hidden_dropout_prob=0.1,
                     attention_probs_dropout_prob=0.1, max_position_embeddings=512, type_vocab_size=2,
                     initializer_range=0.02, layer_norm_eps=1e-12, pad_token_id=0,
                     position_embedding_type="absolute")


@unittest.skipUnless(AVAILABLE or REQUIRED, "coremltools, numpy, torch and transformers are not installed")
class CoreMLConversionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not AVAILABLE:
            raise AssertionError("DIVEID_REQUIRE_CONVERSION=1 but the conversion tooling is not installed")
        import provision_real_encoder as provision
        from transformers import BertConfig, BertModel
        cls.provision = provision
        cls.temporary = tempfile.TemporaryDirectory()
        root = Path(cls.temporary.name)
        cls.model_dir = root / "minilm-architecture"
        torch.manual_seed(20261024)
        BertModel(BertConfig(**MINILM_CONFIG)).eval().save_pretrained(cls.model_dir)
        lock = json.loads((provision.TOOLS / "real-encoder.v1.json").read_text())
        cls.contract = provision.contract_for(lock, "Semantic-test.vocab.json")
        cls.package = root / "Semantic-test.mlpackage"
        provision.convert(cls.model_dir, cls.contract, cls.package)

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temporary"):
            cls.temporary.cleanup()

    def test_conversion_produces_the_app_contract_interface(self):
        import coremltools as ct
        spec = ct.utils.load_spec(str(self.package))
        length = self.contract["maximumSequenceLength"]
        inputs = {feature.name: feature.type.multiArrayType for feature in spec.description.input}
        self.assertEqual(sorted(inputs), sorted([self.contract["inputIDsFeature"], self.contract["attentionMaskFeature"]]))
        for array in inputs.values():
            self.assertEqual(list(array.shape), [1, length])
            self.assertEqual(array.dataType, ct.proto.FeatureTypes_pb2.ArrayFeatureType.INT32)
        outputs = [feature.name for feature in spec.description.output]
        self.assertEqual(outputs, [self.contract["outputFeature"]])
        self.assertEqual(spec.WhichOneof("Type"), "mlProgram")
        self.assertGreaterEqual(spec.specificationVersion, 9)  # iOS 18 deployment target

    @unittest.skipUnless(sys.platform == "darwin", "Core ML predictions need macOS")
    def test_converted_graph_honours_the_attention_mask(self):
        import numpy as np
        import coremltools as ct
        from coreml_parity import load_spec, masked_mean_normalized
        from transformers import AutoModel
        tolerance = load_spec()["tolerances"]["coreMLCosineMinimum"]
        model = AutoModel.from_pretrained(self.model_dir).eval()
        converted = ct.models.MLModel(str(self.package), compute_units=ct.ComputeUnit.ALL)
        length = self.contract["maximumSequenceLength"]
        generator = np.random.default_rng(7)
        for used in (2, 17, length):
            ids = np.zeros((1, length), dtype=np.int32); mask = np.zeros((1, length), dtype=np.int32)
            ids[0, :used] = generator.integers(1000, 30000, used); ids[0, 0] = 101; ids[0, used - 1] = 102
            mask[0, :used] = 1
            with torch.inference_mode():
                hidden = model(input_ids=torch.tensor(ids[:, :used], dtype=torch.long),
                               attention_mask=torch.tensor(mask[:, :used], dtype=torch.long)).last_hidden_state[0].numpy()
            expected = masked_mean_normalized(hidden, [1] * used)
            output = converted.predict({"input_ids": ids, "attention_mask": mask})["last_hidden_state"][0]
            actual = masked_mean_normalized(np.asarray(output, dtype=np.float32), mask[0].tolist())
            self.assertGreaterEqual(float(np.dot(expected, actual)), tolerance, f"{used} tokens")


if __name__ == "__main__":
    unittest.main()
