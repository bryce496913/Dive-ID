#!/usr/bin/env python3
"""Write DiveIDTests/Fixtures/TokenizerParity.v2.json, the tokenizer fixture shared by the
Swift `WordPieceTokenizer` and the Python mirror (`build_embedding_index.ReferenceWordPieceTokenizer`).

- `basicTokenCases` record what the pinned fast tokenizer's BertNormalizer and
  BertPreTokenizer produce (the `tokenizers` version in requirements-real-encoder.in),
  so both implementations are checked against the real tokenizer, not only each other.
  Writing refuses if the mirror disagrees with it on any case.
- `cases` record full encodings (IDs and attention mask) of the mirror on a small vocabulary.

    python3 Tools/SemanticSearch/write_tokenizer_parity_fixture.py   # needs tokenizers installed
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_embedding_index as builder  # noqa: E402

OUTPUT = HERE.parents[1] / "DiveIDTests/Fixtures/TokenizerParity.v2.json"
PINNED_TOKENIZERS = next(line.split("==")[1].split("#")[0].strip() for line in (HERE / "requirements-real-encoder.in").read_text().splitlines()
                         if line.startswith("tokenizers=="))

VOCABULARY = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "query", "passage", "cafe", "fish", "div", "##ing", "reef",
              "one", "two", "three", "four", "five", "six", "hello", "world", ",", "-", "!", ":", "'", "s", "diver"]

CONTRACT = {
    "contractVersion": 1, "modelIdentifier": "fixture.wordpiece", "modelVersion": "1", "embeddingDimension": 2,
    "tokenizerIdentifier": "fixture-bert-wordpiece-v2", "preprocessingIdentifier": "fixture-preprocess-v1",
    "vocabularyFile": "tokenizer-parity-fixture.json", "lowercase": True, "stripAccents": True,
    "maximumSequenceLength": 12, "truncation": "end", "clsToken": "[CLS]", "separatorToken": "[SEP]",
    "paddingToken": "[PAD]", "unknownToken": "[UNK]", "queryPrefix": "query: ", "documentPrefix": "passage: ",
    "inputIDsFeature": "ids", "attentionMaskFeature": "mask", "tokenTypeIDsFeature": None, "outputFeature": "hidden",
    "pooling": "meanMasked", "normalizeL2": True,
}

ENCODING_CASES = [
    ("uppercase", "HELLO WORLD", False, "end"),
    ("accents", "CAFÉ fish", False, "end"),
    ("punctuation", "hello, reef-fish!", False, "end"),
    ("apostrophe", "diver's fish", False, "end"),
    ("unknown", "mystery fish", False, "end"),
    ("wordpiece", "DIVING", False, "end"),
    ("long-word", "fish " + "a" * 101, False, "end"),
    ("control-and-whitespace", "reef fish\x00​\tworld", False, "end"),
    ("end-truncation", "one two three four five six fish one two three", False, "end"),
    ("beginning-truncation", "one two three four five six fish one two three", False, "beginning"),
    ("query-prefix", "reef", False, "end"),
    ("document-prefix", "reef", True, "end"),
]

# Characters where BERT's rules are easy to get wrong: punctuation, symbols, accents, CJK,
# control, format and whitespace characters, unassigned code points, and case mappings.
BASIC_TEXTS = [
    "CAFÉ-striped fish near the reef!", "diver's blue—green animal; 12cm", "juvenile\tang\nwith yellow tail",
    "unaffable bioluminescence ???", "Colours: black, brown, gray and orange.", "Dorsal fin: 17–18 spines, 6–7 soft rays.",
    "50°C × 3 ± 2 €5 $5 #1 @me ~ok", "«quoted» „low“ ‹single›", "naïve résumé coöperate é", "ø Ø ł Ł đ ß æ œ ı",
    "İstanbul KELVIN K", "ΣΊΣΥΦΟΣ", "海洋魚 fish 鱼", "a\x0bb\x0cc\x85d\x1ce", "zero​width­soft﻿bom",
    " nbsp em　ideo", "x\x00y�z", "unassigned⁥kept", "क्षेत्र हिन्दी", "ﬁsh ligature", "emoji 🐠🐟 fish",
    "hyphen-ated--double", "a.b.c", "under_score (paren) [bracket] {brace}", "",
]


def main():
    try:
        import tokenizers
        from tokenizers.normalizers import BertNormalizer
        from tokenizers.pre_tokenizers import BertPreTokenizer
    except ImportError:
        raise SystemExit(f"install tokenizers=={PINNED_TOKENIZERS} to write the fixture")
    if tokenizers.__version__ != PINNED_TOKENIZERS:
        raise SystemExit(f"tokenizers {tokenizers.__version__} is not the pinned {PINNED_TOKENIZERS}")
    normalizer = BertNormalizer(clean_text=True, handle_chinese_chars=True,
                                strip_accents=CONTRACT["stripAccents"], lowercase=CONTRACT["lowercase"])
    pre_tokenizer = BertPreTokenizer()
    basic_cases = []
    for text in BASIC_TEXTS:
        expected = [word for word, _ in pre_tokenizer.pre_tokenize_str(normalizer.normalize_str(text))]
        mirror = builder.basic_tokens(text, CONTRACT["lowercase"], CONTRACT["stripAccents"])
        if mirror != expected:
            raise SystemExit(f"mirror differs from tokenizers {PINNED_TOKENIZERS} for {text!r}: {mirror} != {expected}")
        basic_cases.append({"text": text, "tokens": expected})
    vocabulary = {token: index for index, token in enumerate(VOCABULARY)}
    contract = dict(CONTRACT, vocabularySHA256=builder.vocabulary_checksum(vocabulary))
    contract["tokenizerFingerprint"] = builder.tokenizer_fingerprint(contract, vocabulary)
    cases = []
    for name, text, document, truncation in ENCODING_CASES:
        encoded = builder.ReferenceWordPieceTokenizer(vocabulary, dict(contract, truncation=truncation)).encode(text, document=document)
        cases.append({"name": name, "text": text, "document": document, "truncation": truncation,
                      "inputIDs": encoded["input_ids"], "attentionMask": encoded["attention_mask"]})
    fixture = {"schemaVersion": 2, "basicTokenizerSource": f"tokenizers {PINNED_TOKENIZERS} BertNormalizer + BertPreTokenizer",
               "vocabulary": vocabulary, "contract": contract, "basicTokenCases": basic_cases, "cases": cases}
    OUTPUT.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(HERE.parents[1])}: {len(basic_cases)} basic and {len(cases)} encoding cases")


if __name__ == "__main__":
    main()
