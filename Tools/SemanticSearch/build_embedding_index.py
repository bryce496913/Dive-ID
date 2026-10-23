#!/usr/bin/env python3
"""Build an index using the exact tokenizer contract consumed by Dive-ID."""
import argparse
import hashlib
import json
import unicodedata
from pathlib import Path


TOKENIZER_CONTRACT_FIELDS = (
    "tokenizerIdentifier", "preprocessingIdentifier", "lowercase", "stripAccents",
    "maximumSequenceLength", "truncation", "clsToken", "separatorToken",
    "paddingToken", "unknownToken", "queryPrefix", "documentPrefix",
    "pooling", "normalizeL2",
)


def canonical_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def vocabulary_checksum(vocabulary):
    return hashlib.sha256(canonical_json(vocabulary).encode("utf-8")).hexdigest()


# The basic tokenization below follows BERT's (BertNormalizer + BertPreTokenizer in the
# pinned `tokenizers`); the family name is part of every fingerprint, so artifacts built
# with the earlier rule (which dropped punctuation) no longer validate.
TOKENIZER_FAMILY = "BertWordPiece"
MAX_INPUT_CHARS_PER_WORD = 100
# Unicode White_Space, as Rust's char::is_whitespace (Python's str.isspace also accepts U+001C–U+001F).
WHITE_SPACE = frozenset("\t\n\x0b\x0c\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008"
                        "\u2009\u200a\u2028\u2029\u202f\u205f\u3000")
OTHER_DROPPED = frozenset(("Cc", "Cf", "Cs", "Co"))
ASCII_PUNCTUATION = frozenset("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
CJK_RANGES = ((0x4E00, 0x9FFF), (0x3400, 0x4DBF), (0x20000, 0x2A6DF), (0x2A700, 0x2B73F),
              (0x2B740, 0x2B81F), (0x2B820, 0x2CEAF), (0xF900, 0xFAFF), (0x2F800, 0x2FA1F))


def tokenizer_fingerprint(contract, vocabulary):
    identity = {key: contract[key] for key in TOKENIZER_CONTRACT_FIELDS}
    identity.update({"tokenizerFamily": TOKENIZER_FAMILY, "vocabularySHA256": vocabulary_checksum(vocabulary)})
    return hashlib.sha256(canonical_json(identity).encode("utf-8")).hexdigest()


def basic_tokens(text, lowercase, strip_accents):
    """BERT's basic tokenization, as the pinned fast tokenizer applies it:
    1. clean: drop NUL, U+FFFD and control, format, surrogate and private-use characters
       (Cc, Cf, Cs, Co; unassigned code points are kept) except tab, newline and return;
       every whitespace character becomes a space;
    2. put spaces around CJK ideographs;
    3. strip accents (NFD, then drop nonspacing marks), then lowercase character by character;
    4. split on whitespace, and make every punctuation character (ASCII punctuation or a
       Unicode P* character) a token of its own."""
    cleaned = []
    for character in text:
        if character in "\t\n\r":
            cleaned.append(" ")
        elif character in ("\x00", "\ufffd") or unicodedata.category(character) in OTHER_DROPPED:
            continue
        else:
            cleaned.append(" " if character in WHITE_SPACE else character)
    spaced = []
    for character in cleaned:
        if any(low <= ord(character) <= high for low, high in CJK_RANGES):
            spaced += [" ", character, " "]
        else:
            spaced.append(character)
    normalized = "".join(spaced)
    if strip_accents:
        normalized = "".join(c for c in unicodedata.normalize("NFD", normalized) if unicodedata.category(c) != "Mn")
    if lowercase:
        normalized = "".join(c.lower() for c in normalized)
    tokens, current = [], []
    for character in normalized:
        if character in WHITE_SPACE:
            if current:
                tokens.append("".join(current)); current = []
        elif character in ASCII_PUNCTUATION or unicodedata.category(character).startswith("P"):
            if current:
                tokens.append("".join(current)); current = []
            tokens.append(character)
        else:
            current.append(character)
    if current:
        tokens.append("".join(current))
    return tokens


class ReferenceWordPieceTokenizer:
    """A deliberately small mirror of Swift's ``WordPieceTokenizer``."""

    def __init__(self, vocabulary, contract):
        if not isinstance(vocabulary, dict) or not vocabulary:
            raise ValueError("vocabulary must be a non-empty token-to-ID object")
        if any(not isinstance(token, str) or not isinstance(identifier, int) or isinstance(identifier, bool)
               or identifier < 0 for token, identifier in vocabulary.items()):
            raise ValueError("vocabulary tokens and IDs must be strings and non-negative integers")
        if len(set(vocabulary.values())) != len(vocabulary):
            raise ValueError("vocabulary IDs must be unique")
        for field in TOKENIZER_CONTRACT_FIELDS:
            if field not in contract:
                raise ValueError(f"contract missing tokenizer field: {field}")
        for field in ("clsToken", "separatorToken", "paddingToken", "unknownToken"):
            if contract[field] not in vocabulary:
                raise ValueError(f"contract {field} is absent from vocabulary")
        if contract["truncation"] not in ("end", "beginning"):
            raise ValueError("contract truncation must be end or beginning")
        if not isinstance(contract["maximumSequenceLength"], int) or contract["maximumSequenceLength"] < 2:
            raise ValueError("maximumSequenceLength must be an integer of at least two")
        if not all(isinstance(contract[field], bool) for field in ("lowercase", "stripAccents")):
            raise ValueError("lowercase and stripAccents must be booleans")
        self.vocabulary = vocabulary
        self.contract = contract

    def _word_pieces(self, word):
        # As the pinned WordPiece model: the length limit comes before the vocabulary lookup.
        if len(word) > MAX_INPUT_CHARS_PER_WORD:
            return [self.contract["unknownToken"]]
        if word in self.vocabulary:
            return [word]
        pieces, start = [], 0
        while start < len(word):
            match = None
            for end in range(len(word), start, -1):
                candidate = word[start:end] if start == 0 else "##" + word[start:end]
                if candidate in self.vocabulary:
                    match = candidate
                    start = end
                    break
            if match is None:
                return [self.contract["unknownToken"]]
            pieces.append(match)
        return pieces

    def encode(self, value, document=False):
        text = self.contract["documentPrefix" if document else "queryPrefix"] + value
        words = basic_tokens(text, self.contract["lowercase"], self.contract["stripAccents"])
        pieces = [piece for word in words for piece in self._word_pieces(word)]
        available = self.contract["maximumSequenceLength"] - 2
        if len(pieces) > available:
            pieces = pieces[:available] if self.contract["truncation"] == "end" else pieces[-available:]
        ids = ([self.vocabulary[self.contract["clsToken"]]] +
               [self.vocabulary.get(piece, self.vocabulary[self.contract["unknownToken"]]) for piece in pieces] +
               [self.vocabulary[self.contract["separatorToken"]]])
        mask = [1] * len(ids)
        padding = self.contract["maximumSequenceLength"] - len(ids)
        ids += [self.vocabulary[self.contract["paddingToken"]]] * padding
        mask += [0] * padding
        return {"input_ids": ids, "attention_mask": mask}


def _hf_wordpiece_family(tokenizer):
    backend = getattr(tokenizer, "backend_tokenizer", None)
    if backend is not None and type(getattr(backend, "model", None)).__name__ == "WordPiece":
        return True
    return getattr(tokenizer, "wordpiece_tokenizer", None) is not None


def validate_hf_tokenizer(tokenizer, contract, vocabulary):
    """Prove HF model metadata agrees, even though reference code performs encoding."""
    if not _hf_wordpiece_family(tokenizer):
        raise ValueError("HF tokenizer family is not WordPiece")
    hf_vocabulary = tokenizer.get_vocab()
    if hf_vocabulary != vocabulary:
        raise ValueError("HF and contract vocabulary contents differ")
    expected_tokens = {
        "cls_token": contract["clsToken"], "sep_token": contract["separatorToken"],
        "pad_token": contract["paddingToken"], "unk_token": contract["unknownToken"],
    }
    for attribute, expected in expected_tokens.items():
        if getattr(tokenizer, attribute, None) != expected:
            raise ValueError(f"HF {attribute} does not match contract")
        if getattr(tokenizer, attribute + "_id", None) != vocabulary[expected]:
            raise ValueError(f"HF {attribute}_id does not match contract vocabulary")
    basic = getattr(tokenizer, "basic_tokenizer", None)
    if basic is not None:
        if bool(getattr(basic, "do_lower_case", None)) != contract["lowercase"]:
            raise ValueError("HF lowercase behavior does not match contract")
        strip = getattr(basic, "strip_accents", None)
        effective_strip = contract["lowercase"] if strip is None else bool(strip)
        if effective_strip != contract["stripAccents"]:
            raise ValueError("HF accent stripping does not match contract")
    elif not getattr(tokenizer, "is_fast", False):
        raise ValueError("HF tokenizer normalization behavior cannot be inspected")
    else:
        normalizer = json.loads(tokenizer.backend_tokenizer.normalizer.__getstate__())
        def find_bert(value):
            if isinstance(value, dict):
                if value.get("type") == "BertNormalizer": return value
                for child in value.values():
                    found = find_bert(child)
                    if found is not None: return found
            if isinstance(value, list):
                for child in value:
                    found = find_bert(child)
                    if found is not None: return found
            return None
        bert = find_bert(normalizer)
        if bert is None or bert.get("lowercase") is not contract["lowercase"]:
            raise ValueError("HF lowercase behavior does not match contract")
        strip = bert.get("strip_accents")
        effective_strip = contract["lowercase"] if strip is None else strip
        if effective_strip is not contract["stripAccents"]:
            raise ValueError("HF accent stripping does not match contract")
    maximum = getattr(tokenizer, "model_max_length", None)
    if not isinstance(maximum, int) or maximum < contract["maximumSequenceLength"]:
        raise ValueError("HF model maximum length cannot reproduce contract")
    # Never inherit the HF default. Configure and then prove the requested side.
    tokenizer.truncation_side = "right" if contract["truncation"] == "end" else "left"
    if tokenizer.truncation_side != ("right" if contract["truncation"] == "end" else "left"):
        raise ValueError("HF truncation side cannot reproduce contract")


def catalogue_fingerprint(rows, schema):
    value = "\n".join(sorted(f"{r['species_id'].lower()}:{r['document_fingerprint']}" for r in rows))
    return hashlib.sha256(f"{schema}\n{value}".encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--contract", type=Path, required=True)
    parser.add_argument("--model", required=True, help="local HF model directory; network downloads are not performed")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    contract = json.loads(args.contract.read_text(encoding="utf-8"))
    vocabulary_path = args.contract.parent / contract.get("vocabularyFile", "")
    if not vocabulary_path.is_file():
        raise SystemExit(f"contract vocabulary is missing: {vocabulary_path}")
    vocabulary = json.loads(vocabulary_path.read_text(encoding="utf-8"))
    try:
        reference = ReferenceWordPieceTokenizer(vocabulary, contract)
    except ValueError as error:
        raise SystemExit(f"unsupported tokenizer contract: {error}") from error
    rows = [json.loads(line) for line in args.corpus.read_text().splitlines() if line.strip()]
    if not rows or len({r["species_id"] for r in rows}) != len(rows):
        raise SystemExit("empty corpus or duplicate species IDs")
    if contract.get("pooling") not in ("meanMasked", "cls"):
        raise SystemExit("modelOutput pooling cannot be reproduced from token hidden states")
    if contract.get("normalizeL2") is not True:
        raise SystemExit("Dive-ID contract requires L2 normalization")

    try:
        import torch
        from transformers import AutoModel, AutoTokenizer
    except ImportError as exc:
        raise SystemExit("Install developer dependencies: pip install torch transformers") from exc
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    try:
        validate_hf_tokenizer(tokenizer, contract, vocabulary)
    except ValueError as error:
        raise SystemExit(f"HF tokenizer is incompatible: {error}") from error
    model = AutoModel.from_pretrained(args.model, local_files_only=True).eval()
    vectors = []
    with torch.inference_mode():
        for row in rows:
            encoded_values = reference.encode(row["search_text"], document=True)
            encoded = {key: torch.tensor([value], dtype=torch.long) for key, value in encoded_values.items()}
            hidden = model(**encoded).last_hidden_state
            if contract["pooling"] == "cls":
                pooled = hidden[:, 0, :]
            else:
                mask = encoded["attention_mask"].unsqueeze(-1)
                pooled = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1)
            normalized = torch.nn.functional.normalize(pooled, p=2, dim=1)[0].float().numpy()
            # Swift decodes Float32; the shortest Float32 text is exact and about half the size.
            vector = [float(str(value)) for value in normalized]
            if len(vector) != contract["embeddingDimension"]:
                raise SystemExit("encoder dimension does not match contract")
            vectors.append(vector)

    schema = rows[0]["document_schema_version"]
    if any(r["document_schema_version"] != schema for r in rows): raise SystemExit("mixed document schemas")
    pack_id, pack_version = rows[0]["pack_id"], rows[0]["pack_version"]
    if any((r["pack_id"], r["pack_version"]) != (pack_id, pack_version) for r in rows): raise SystemExit("mixed packs")
    output = {"metadata": {"modelIdentifier": contract["modelIdentifier"], "modelVersion": contract["modelVersion"],
        "embeddingDimension": contract["embeddingDimension"], "searchDocumentSchemaVersion": schema,
        "documentFingerprint": catalogue_fingerprint(rows, schema), "packID": pack_id, "packVersion": pack_version,
        "tokenizerIdentifier": contract["tokenizerIdentifier"], "preprocessingIdentifier": contract["preprocessingIdentifier"],
        "tokenizerFingerprint": tokenizer_fingerprint(contract, vocabulary),
        "vocabularySHA256": vocabulary_checksum(vocabulary), "indexFormatVersion": 2}, "records": [
        {"speciesID": row["species_id"], "documentFingerprint": row["document_fingerprint"], "vector": vector}
        for row, vector in zip(rows, vectors)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, separators=(",", ":"), sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
