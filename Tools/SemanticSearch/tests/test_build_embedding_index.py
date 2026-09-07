import copy
import importlib.util
import json
import unittest
from pathlib import Path
from types import SimpleNamespace

MODULE = Path(__file__).parents[1] / "build_embedding_index.py"
spec = importlib.util.spec_from_file_location("build_embedding_index", MODULE)
builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
FIXTURE = Path(__file__).parents[3] / "DiveIDTests/Fixtures/TokenizerParity.v1.json"


class FakeWordPieceTokenizer:
    is_fast = False
    model_max_length = 512
    wordpiece_tokenizer = object()

    def __init__(self, vocabulary, contract):
        self._vocabulary = vocabulary
        self.basic_tokenizer = SimpleNamespace(do_lower_case=contract["lowercase"], strip_accents=contract["stripAccents"])
        self.cls_token = contract["clsToken"]; self.sep_token = contract["separatorToken"]
        self.pad_token = contract["paddingToken"]; self.unk_token = contract["unknownToken"]
        self.cls_token_id = vocabulary[self.cls_token]; self.sep_token_id = vocabulary[self.sep_token]
        self.pad_token_id = vocabulary[self.pad_token]; self.unk_token_id = vocabulary[self.unk_token]
        self.truncation_side = "right"

    def get_vocab(self): return self._vocabulary


class EmbeddingIndexTokenizerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_reference_tokenizer_matches_committed_fixture(self):
        for case in self.fixture["cases"]:
            contract = dict(self.fixture["contract"], truncation=case["truncation"])
            encoded = builder.ReferenceWordPieceTokenizer(self.fixture["vocabulary"], contract).encode(
                case["text"], document=case["document"])
            self.assertEqual(encoded["input_ids"], case["inputIDs"], case["name"])
            self.assertEqual(encoded["attention_mask"], case["attentionMask"], case["name"])

    def test_beginning_contract_explicitly_corrects_right_hf_truncation(self):
        contract = dict(self.fixture["contract"], truncation="beginning")
        tokenizer = FakeWordPieceTokenizer(self.fixture["vocabulary"], contract)
        self.assertEqual(tokenizer.truncation_side, "right")
        builder.validate_hf_tokenizer(tokenizer, contract, self.fixture["vocabulary"])
        self.assertEqual(tokenizer.truncation_side, "left")

    def test_rejects_wrong_family_vocabulary_normalization_tokens_and_length(self):
        contract = self.fixture["contract"]; vocabulary = self.fixture["vocabulary"]
        mutations = []
        wrong_family = FakeWordPieceTokenizer(vocabulary, contract); wrong_family.wordpiece_tokenizer = None
        mutations.append(wrong_family)
        wrong_vocab = FakeWordPieceTokenizer(dict(vocabulary, extra=99), contract); mutations.append(wrong_vocab)
        wrong_case = FakeWordPieceTokenizer(vocabulary, contract); wrong_case.basic_tokenizer.do_lower_case = False; mutations.append(wrong_case)
        wrong_accents = FakeWordPieceTokenizer(vocabulary, contract); wrong_accents.basic_tokenizer.strip_accents = False; mutations.append(wrong_accents)
        wrong_cls = FakeWordPieceTokenizer(vocabulary, contract); wrong_cls.cls_token = "bad"; mutations.append(wrong_cls)
        too_short = FakeWordPieceTokenizer(vocabulary, contract); too_short.model_max_length = 4; mutations.append(too_short)
        for tokenizer in mutations:
            with self.subTest(tokenizer=tokenizer), self.assertRaises(ValueError):
                builder.validate_hf_tokenizer(tokenizer, contract, vocabulary)

    def test_fingerprint_changes_for_every_preprocessing_field_and_vocabulary(self):
        contract = self.fixture["contract"]; vocabulary = self.fixture["vocabulary"]
        original = builder.tokenizer_fingerprint(contract, vocabulary)
        changes = {
            "tokenizerIdentifier": "other", "preprocessingIdentifier": "other", "lowercase": False,
            "stripAccents": False, "maximumSequenceLength": 9, "truncation": "beginning",
            "clsToken": "query", "separatorToken": "query", "paddingToken": "query",
            "unknownToken": "query", "queryPrefix": "q ", "documentPrefix": "d ",
            "pooling": "cls", "normalizeL2": False,
        }
        for field, value in changes.items():
            self.assertNotEqual(original, builder.tokenizer_fingerprint(dict(contract, **{field: value}), vocabulary), field)
        changed_vocabulary = copy.deepcopy(vocabulary); changed_vocabulary["fish"] = 99
        self.assertNotEqual(original, builder.tokenizer_fingerprint(contract, changed_vocabulary))


if __name__ == "__main__": unittest.main()
