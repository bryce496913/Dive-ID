"""Trait extraction from FishBase/SeaLifeBase text fields, clause by clause.

Every trait is found in a named source field and written in short original wording;
nothing is inferred from general knowledge. Three rules keep text from becoming false
clues:

- Negation: a term after "no", "not", "without", "lacks", "never" (within three
  words), or followed by "absent"/"lacking", is not asserted.
- Life stage and sex: a clause about juveniles, males or females feeds that
  appearance variant, never the main profile. "Adult" clauses feed the main profile.
- Ambiguity: a hedged clause ("may", "sometimes", "with or without") or a clause
  comparing stages or sexes ("males brighter than females") asserts nothing; it
  raises a trait_ambiguous risk flag so a reviewer sees it.

`extract` returns the traits, the variants, the flags and a trace that names the
source field of every value.
"""
from __future__ import annotations

import re

COLORS = {"blue": ["blue", "bluish", "navy", "turquoise", "cyan"], "yellow": ["yellow", "yellowish", "gold", "golden"],
          "red": ["red", "reddish", "scarlet", "crimson"], "white": ["white", "whitish"], "black": ["black", "blackish"],
          "brown": ["brown", "brownish"], "olive": ["olive"], "orange": ["orange", "orangish"],
          "silver": ["silver", "silvery"], "green": ["green", "greenish"], "gray": ["gray", "grey", "grayish", "greyish"],
          "pink": ["pink", "pinkish"]}
# Pink is a wording colour only: it is not in the catalogue colour vocabulary.
VOCABULARY_COLORS = {c for c in COLORS if c != "pink"}
COLOR_WORD = {w: c for c, words in COLORS.items() for w in words}
COLOR_RE = "(?:" + "|".join(sorted(COLOR_WORD, key=len, reverse=True)) + ")"
MARKINGS = {"spots": ["spot", "spots", "spotted", "dots", "dotted", "ocellus", "ocelli", "flecked", "flecks", "speckled", "specks", "freckled"],
            "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars", "barred", "lines"],
            "patches": ["patch", "patches", "blotch", "blotches"], "saddles": ["saddle", "saddles"]}
MARKING_WORD = {w: m for m, words in MARKINGS.items() for w in words}
FIN_WORDS = {"pectoral": "pectoral", "pelvic": "pelvic", "ventral": "pelvic", "dorsal": "dorsal", "anal": "anal", "caudal": "caudal"}
FIN_RE = "(?:pectoral|pelvic|ventral|dorsal|anal|caudal)"
HABITAT_WORDS = {"sand": "sand", "sandy": "sand", "rubble": "rubble", "lagoon": "lagoon", "lagoons": "lagoon", "seagrass": "seagrass",
                 "seagrasses": "seagrass", "eelgrass": "seagrass", "mangrove": "mangrove", "mangroves": "mangrove", "wreck": "wreck",
                 "wrecks": "wreck", "anemone": "anemone", "anemones": "anemone"}
NEGATORS = {"no", "not", "without", "lacks", "lack", "lacking", "never", "non", "nor"}
POST_NEGATORS = {"absent", "lacking", "missing"}
# "can be seen/found" reports an observation, not uncertainty about the trait.
HEDGE_RE = re.compile(r"\b(?:may|might|sometimes|occasionally|rarely|with or without|or not|in some|some individuals|possibly)\b|\bcan be\b(?!\s+(?:seen|found|observed))")
STAGE_RE = {"juvenile": re.compile(r"\b(?:juveniles?|young|subadults?|juv)\b"),
            "male": re.compile(r"\b(?<!fe)males?\b"),
            "female": re.compile(r"\bfemales?\b"),
            "adult": re.compile(r"\badults?\b")}
EQUALITY_RE = re.compile(r"\b(?:males? alike females?|alike in both sexes|sexes alike)\b")
REF_RE = re.compile(r"\((?:Ref|see Ref)\.?[^)]*\)|\bRef\.\s*[\d,;: ]+")
TAG_RE = re.compile(r"<[A-Za-z/][^>]*>")
DESCRIPTION_FIELDS = ("morphdat.AddChars", "morphdat.RemarkSex")
BIOLOGY_FIELDS = ("species.Comments", "ecology.AddRems", "ecology.AssociationsWith")
RULES = frozenset({"negation", "stage", "hedge"})


def normalize(text):
    text = TAG_RE.sub(" ", str(text or ""))
    text = text.lower().replace("colour", "color").replace("-", " ").replace("/", " ")
    return re.sub(r"[^a-z0-9 ]+", " ", text)


def clauses(text):
    """Sentences and semicolon parts; a parenthetical is its own clause."""
    text = REF_RE.sub(" ", TAG_RE.sub(" ", str(text or "")))
    parts = []
    for paren in re.findall(r"\(([^()]*)\)", text):
        parts.append(paren)
    text = re.sub(r"\([^()]*\)", " ", text)
    for sentence in re.split(r"[.;:]\s+|\n+|\.$", text):
        parts.extend(p for p in re.split(r",\s+(?=(?:juveniles?|males?|females?|adults?|young)\b)", sentence, flags=re.I))
    return [" ".join(normalize(p).split()) for p in parts if normalize(p).strip()]


def stages_of(clause):
    found = {stage for stage, pattern in STAGE_RE.items() if pattern.search(clause)}
    return found


def negated(tokens, index, rules):
    if "negation" not in rules:
        return False
    before = tokens[max(0, index - 3):index]
    after = tokens[index + 1:index + 3]
    return any(t in NEGATORS for t in before) or any(t in POST_NEGATORS for t in after)


def fin_phrase(fins):
    """['dorsal', 'anal'] -> 'dorsal and anal fins'; caudal is called the tail."""
    fins = list(dict.fromkeys(fins))
    named = [f for f in fins if f != "caudal"]
    paired = len(named) > 1 or (named and named[0] in ("pectoral", "pelvic"))  # pectoral and pelvic fins come in pairs
    parts = ([and_list(named) + (" fins" if paired else " fin")] if named else []) + (["tail"] if "caudal" in fins else [])
    return " and ".join(parts)


def title(words):
    return words[:1].upper() + words[1:]


def and_list(items):
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1] if items else ""


class Traits:
    def __init__(self):
        self.colors, self.markings, self.habitats, self.behaviors = set(), set(), set(), set()
        self.head, self.fins, self.features, self.tail_shapes = [], [], [], []

    def add(self, kind, value):
        target = getattr(self, kind)
        if isinstance(target, set):
            target.add(value)
        elif value not in target:
            target.append(value)

    def empty(self):
        return not any((self.colors, self.markings, self.habitats, self.behaviors, self.head, self.fins, self.features))


def _colors_in(clause, tokens, rules):
    return [COLOR_WORD[t] for i, t in enumerate(tokens) if t in COLOR_WORD and not negated(tokens, i, rules)]


def _clue_patterns(clause, tokens, rules):
    """(kind, value) clues found in one clause; kinds: head, fins, features, tail_shapes, markings."""
    out = []
    def hit(pattern):
        m = re.search(pattern, clause)
        if not m:
            return None
        index = len(clause[:m.start()].split())
        span = len(m.group(0).split())
        return None if any(negated(tokens, index + k, rules) for k in range(span)) else m
    def colour(word):
        return COLOR_WORD.get(word, word)
    if hit(r"\b(?:long|elongate|elongated|prolonged|produced)\s+snout\b|\bsnout\s+(?:very\s+)?(?:long|elongate|elongated|prolonged)\b"):
        out.append(("head", "Long snout"))
    m = hit(rf"\b(?P<c>{COLOR_RE})\s+(?P<parts>(?:(?:snout|forehead|head|{FIN_RE})\s+(?:and\s+)?)+)(?:fins?\b)?")
    if m:
        parts = m.group("parts").split()
        c = title(colour(m.group("c")))
        heads = [p for p in parts if p in ("snout", "forehead")]
        fins = [FIN_WORDS[p] for p in parts if p in FIN_WORDS]
        if heads:
            out.append(("head", f"{c} {and_list(heads)}"))
        if fins:
            out.append(("fins", f"{c} {fin_phrase(fins)}"))
    m = hit(rf"\b(?P<parts>(?:snout|forehead|head)(?:\s+and\s+(?:snout|forehead))?)\s+(?:abruptly\s+|mostly\s+|bright\s+)?(?P<c>{COLOR_RE})\b")
    if m:
        out.append(("head", f"{title(colour(m.group('c')))} {m.group('parts')}"))
    m = hit(rf"\b(?:(?P<part>axil|axils|base|bases|tip|tips)\s+of\s+(?:the\s+)?)?(?P<fins>{FIN_RE}(?:\s+(?:and|or)\s+{FIN_RE})*)\s+fins?\s+(?:are\s+|mostly\s+)?(?P<c>{COLOR_RE})\b")
    if m:
        fins = [FIN_WORDS[f] for f in m.group("fins").split() if f in FIN_WORDS]
        c = title(colour(m.group("c")))
        part = {"axil": "base", "axils": "base", "bases": "base", "tips": "tip"}.get(m.group("part"), m.group("part"))
        # Only part of the fin is coloured ("axil of pectoral fin black"): say which part.
        out.append(("fins", f"{c} {part} of the {fin_phrase(fins)}" if part else f"{c} {fin_phrase(fins)}"))
    m = hit(rf"\b(?P<adj>pale\s+|dark\s+)?(?P<c>{COLOR_RE})\s+(?P<noun>margins?|edges?|borders?)\b")
    fins = [FIN_WORDS[t] for t in tokens if t in FIN_WORDS]
    if m and re.search(r"\b(?:band|bar|stripe|spot|patch|saddle|blotch|ocellus)\b", clause) and (not fins or m.group("noun").startswith("border")):
        m = None  # the border of a band, saddle or spot, not a fin margin
    if m:
        label = title((m.group("adj") or "") + colour(m.group("c")))
        out.append(("fins", f"{label} margins on the {fin_phrase(fins)}") if fins else ("features", f"{label} margins"))
        out.append(("markings", "fin edge"))
    m = hit(rf"\bteeth\s+(?P<c>{COLOR_RE})\b|\b(?P<c2>{COLOR_RE})\s+teeth\b")
    if m:
        out.append(("head", f"{title(colour(m.group('c') or m.group('c2')))} teeth"))
        out.append(("markings", "teeth"))
    if hit(r"\b(?:preopercular|preopercle|cheek|opercular)\s+spines?\b"):
        out.append(("head", "Prominent cheek spine"))
        out.append(("markings", "spines"))
    if hit(r"\bgroove\s+(?:in\s+)?front\s+of\s+(?:the\s+)?eye\b|\bfront\s+of\s+(?:the\s+)?eye\s+with\s+(?:a\s+)?(?:deep\s+)?groove\b"):
        out.append(("head", "Deep groove in front of the eye"))
    if hit(r"\bupturned\s+mouth\b|\bmouth\s+upturned\b"):
        out.append(("head", "Upturned mouth"))
    if hit(r"\bprotruding\s+chin\b"):
        out.append(("head", "Protruding chin"))
    if hit(r"\b(?:projecting|protruding)\s+lower\s+jaw\b"):
        out.append(("head", "Projecting lower jaw"))
    if hit(r"\bconvex(?:ity)?\s+(?:of\s+)?(?:the\s+)?snout\b|\bsnout\s+(?:profile\s+)?(?:more\s+|strongly\s+)?convex\b"):
        out.append(("head", "Rounded snout profile"))
    m = hit(r"\b(?:band|bar|stripe)\s+(?P<where>behind|through|across|over)\s+(?:the\s+)?eyes?\b")
    if m:
        before = clause[:m.start()].split()
        edge = next((COLOR_WORD[w] for i, w in enumerate(before[:-1]) if w in COLOR_WORD and before[i + 1] == "edged"), None)
        main = [COLOR_WORD[w] for i, w in enumerate(before) if w in COLOR_WORD and not (i + 1 < len(before) and before[i + 1] == "edged")]
        lead = title(main[-1]) + " band" if main else "Band"
        out.append(("head", f"{lead} {m.group('where')} the eye" + (f", {edge}-edged" if edge else "")))
        out.append(("markings", "eye stripe"))
    if hit(r"\bhead\s+bar\b"):
        out.append(("head", "Bar across the head"))
        out.append(("markings", "stripes"))
    if re.search(r"\b(?:band|bar|stripe|patch|spot|mark)\b", clause) and re.search(r"\bgill\s+(?:opening|cover|slit)", clause) and re.search(r"\b(?:posterior|behind|after)\b", clause):
        cs = _colors_in(clause, tokens, rules)
        noun = re.search(r"\b(band|bar|stripe|patch|spot|mark)\b", clause).group(1)
        out.append(("features", f"{title(cs[0]) + ' ' if cs else ''}{noun} behind the gill opening".capitalize()))
    if hit(r"\b(?:head\s+and\s+)?(?:anterior|front)\s+(?:half|part)\b.*\b(?:paler|lighter)\b"):
        out.append(("features", "Front half paler than the rear"))
    m = hit(rf"\b(?P<cols>(?:{COLOR_RE}(?:\s+edged)?\s+(?:and\s+)?)+)(?P<noun>stripes|bands|bars|lines)\b")
    if m:
        words = m.group("cols").split()
        edges = [COLOR_WORD[w] for i, w in enumerate(words[:-1]) if w in COLOR_WORD and words[i + 1] == "edged"]
        body = [COLOR_WORD[w] for i, w in enumerate(words) if w in COLOR_WORD and not (i + 1 < len(words) and words[i + 1] == "edged")]
        if body:
            noun = m.group("noun")
            out.append(("features", title(and_list(list(dict.fromkeys(body))) + " " + noun) + (f" with {and_list(edges)} edges" if edges else "")))
    m = hit(rf"\b(?P<adj>dark|pale|{COLOR_RE})?\s*lines?\s+radiating\s+from\s+(?:the\s+)?eyes?\b")
    if m:
        adj = m.group("adj")
        out.append(("features", f"{title(COLOR_WORD.get(adj, adj)) + ' ' if adj else ''}lines radiating from the eye".capitalize()))
    if hit(r"\b(?:first|second|front|anterior|third)?\s*dorsal\s+spines?\s+(?:is\s+|are\s+)?(?:longest|elongate|elongated|very\s+long|tall|high)\b"
           r"|\bspinous\s+(?:portion\s+of\s+(?:the\s+)?)?dorsal\s+fin\s+(?:held\s+)?(?:fully\s+)?erect\b"
           r"|\b(?:high|tall|elevated)\s+(?:spinous\s+|first\s+)?dorsal\b|\bdorsal\s+fin\s+(?:very\s+)?(?:high|tall)\b"):
        out.append(("fins", "Tall front dorsal fin"))
    if hit(r"\belevated\s+anteriorly\b") and "dorsal" in tokens:
        out.append(("fins", "Raised front lobes on the soft dorsal and anal fins" if "anal" in tokens else "Raised front of the soft dorsal fin"))
    if hit(r"\b(?:prolonged|elongate|elongated|filamentous)\s+(?:caudal\s+)?lobes?\b|\blobes?\s+(?:prolonged|elongate|elongated|filamentous)\b"):
        out.append(("fins", "Long tail lobes"))
    if hit(r"\b(?:lancet|scalpel)\s+like\s+spine\b|\bspine\s+on\s+each\s+side\s+of\s+(?:the\s+)?(?:caudal\s+peduncle|tail)\b|\bcaudal\s+(?:peduncle\s+)?spines?\b"):
        out.append(("fins", "Sharp spine on each side of the tail base"))
        out.append(("markings", "spines"))
    if "caudal" in tokens or "tail" in tokens:
        m = hit(r"\b(lunate|crescent|forked|emarginate|rounded|truncate|pointed)\b")
        if m:
            out.append(("tail_shapes", {"crescent": "lunate"}.get(m.group(1), m.group(1))))
    return out


def _biology_patterns(clause, tokens, rules):
    out = []
    def found(pattern):
        m = re.search(pattern, clause)
        if not m:
            return False
        index = len(clause[:m.start()].split())
        return not negated(tokens, index, rules)
    if found(r"\b(?:forms?|forming|in)\s+(?:large\s+|small\s+|loose\s+)*(?:schools?|aggregations?|shoals?)\b|\bschooling\b|(?<!spawning )\baggregations?\b"):
        if not re.search(r"\bspawning\s+aggregations?\b", clause) or re.search(r"\bschool", clause):
            out.append(("behaviors", "schooling"))
    if found(r"\bsolitary\b|\bsingly\b"):
        out.append(("behaviors", "solitary"))
    if found(r"\bin\s+pairs\b"):
        out.append(("features", "Often seen in pairs"))
    if found(r"\bhover(?:s|ing)?\b"):
        out.append(("behaviors", "hovering"))
    if found(r"\bcleaner\b|\bcleans\s+other\b|\bcleaning\s+station"):
        out.append(("behaviors", "cleaning"))
    if found(r"\banemones?\b") and not re.search(r"\bmimic", clause):
        out.append(("behaviors", "anemone association"))
    if found(r"\brock(?:s|ing)?\s+back\s+and\s+forth\b|\bsway(?:s|ing)?\b"):
        out.append(("features", "Sways back and forth with the surge" if "surge" in tokens else "Sways back and forth"))
    m = re.search(r"\bmimic(?:s|ry|king)?\s+(?:of\s+)?(?P<thing>(?:an?\s+|the\s+)?[a-z]+)", clause)
    if m and found(r"\bmimic"):
        out.append(("features", f"Mimics {m.group('thing')}"))
    if found(r"\bnocturnal\b"):
        out.append(("features", "Active at night"))
    for i, t in enumerate(tokens):
        if t in HABITAT_WORDS and not negated(tokens, i, rules):
            out.append(("habitats", HABITAT_WORDS[t]))
    if re.search(r"\bsea\s+grass", clause):
        out.append(("habitats", "seagrass"))
    if re.search(r"\bdrop\s+offs?\b", clause):
        out.append(("habitats", "wall"))
    return out


def extract(fields, rules=RULES):
    """fields: {"morphdat.AddChars": text, "species.Comments": text, ...}.
    Returns {"main": Traits, "variants": {stage: Traits}, "flags": [...], "trace": [...]}."""
    main, variants, flags, trace = Traits(), {}, [], []
    for field, text in fields.items():
        if not text:
            continue
        description = field in DESCRIPTION_FIELDS
        for clause in clauses(text):
            if EQUALITY_RE.search(clause):
                continue
            tokens = clause.split()

            def scan(active):
                if description:
                    return ([("colors", c) for c in _colors_in(clause, tokens, active) if c in VOCABULARY_COLORS]
                            + [("markings", MARKING_WORD[t]) for i, t in enumerate(tokens) if t in MARKING_WORD and not negated(tokens, i, active)]
                            + _clue_patterns(clause, tokens, active))
                return _biology_patterns(clause, tokens, active)
            found = scan(rules)
            hedged = "hedge" in rules and HEDGE_RE.search(clause)
            if hedged and not found:
                found = scan(rules - {"negation"})  # "with or without spots" is still about spots
            if not found:
                continue
            stages = stages_of(clause) if "stage" in rules else set()
            comparison = ({"male", "female"} <= stages) or ({"juvenile", "adult"} <= stages)
            if hedged or comparison:
                kinds = sorted({k for k, _ in found})
                flags.append(f"trait_ambiguous:{'/'.join(kinds)}")
                trace.append({"clause": clause, "source": field, "ambiguous": "hedged" if not comparison else "compares stages or sexes"})
                continue
            targets = [s for s in ("juvenile", "male", "female") if s in stages] or ["main"]
            for target in targets:
                bucket = main if target == "main" else variants.setdefault(target, Traits())
                for kind, value in found:
                    bucket.add(kind, value)
                    trace.append({"target": target, "kind": kind, "value": value, "source": field})
    def source_casing(feature):
        if not feature.startswith("Mimics "):
            return feature
        word = feature.split()[-1]
        for text in fields.values():
            m = re.search(rf"\b{re.escape(word)}\b", TAG_RE.sub(" ", str(text or "")), re.I)
            if m:
                return feature[: -len(word)] + m.group(0)
        return feature
    for bucket in [main, *variants.values()]:
        bucket.features = [source_casing(f) for f in bucket.features]
    for item in trace:
        if item.get("kind") == "features":
            item["value"] = source_casing(item["value"])
    return {"main": main, "variants": {k: v for k, v in variants.items() if not v.empty()}, "flags": sorted(set(flags)), "trace": trace}
