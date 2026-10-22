"""Enrichment stage: build draft LocalSpeciesProfile records from the pinned FishBase/SeaLifeBase release.

Input: NameResolution.csv (resolve.py), the merge plan (merge_plan.py), the staged
distribution snapshot (distribution.py) and the pinned, integrity-checked tables
(fetch.py). Each accepted taxon the merge plan keeps becomes one draft record under the
kept UUID. The rebuilt Tropical Pacific records keep their UUIDs and lose all text that
came from the field-guide book. The 8 Caribbean records are kept as they are (2 are
human-verified) and only reserve their names.

Every field is mapped deterministically from source facts (Docs/GlobalMarine4000ActivationPlan.md §4):
- categories come from the source taxonomy (class, order, family);
- summary, distinguishing features, habitat text and the distribution summary are
  short original wording assembled from source facts, never copied sentences;
- colours, markings, head, fin and tail clues, behaviours and habitats come from the
  source text clause by clause (traits.py): negated traits are not asserted,
  juvenile/male/female traits become appearance variants, and hedged or comparative
  passages assert nothing and raise a trait_ambiguous risk flag;
- every derived value is traced to its source field (ClueTrace.json), and each record's
  dataSources lists the source fields it used;
- fields with no source stay empty or null; nothing is filled from general knowledge.

Output (staging only): review batches of 250 at Data/GlobalMarine/FishBase/Drafts/,
written resumably (an unchanged batch is not rewritten), plus BuildReport.json
(field coverage) and RiskReport.json (per-record risk flags and score).
"""
import argparse
import csv
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "CatalogReview"))
import catalogue_validation  # noqa: E402
import distribution  # noqa: E402
import fetch  # noqa: E402
import traits  # noqa: E402

BUILDER_VERSION = 3
BATCH_SIZE = 250
ACCESSED = "2026-10-21T00:00:00Z"
LICENSE = "CC BY-NC 4.0"
SOURCES = {
    "fb": ("FishBase", "https://www.fishbase.se/summary/SpeciesSummary.php?ID={}"),
    "slb": ("SeaLifeBase", "https://www.sealifebase.se/summary/SpeciesSummary.php?ID={}"),
}

LENGTH_TYPES = {"TL": "totalLength", "SL": "standardLength", "FL": "forkLength", "WD": "discWidth",
                "DL": "discLength", "CL": "carapaceLength", "CW": "carapaceWidth", "SHL": "shellLength",
                "ML": "mantleLength", "BL": "bodyLength"}
LENGTH_WORDS = {"totalLength": "total length", "standardLength": "standard length", "forkLength": "fork length",
                "discWidth": "disc width", "discLength": "disc length", "carapaceLength": "carapace length",
                "carapaceWidth": "carapace width", "shellLength": "shell length", "mantleLength": "mantle length",
                "bodyLength": "body length"}
RAY_ORDERS = {"Myliobatiformes", "Rajiformes", "Rhinopristiformes", "Torpediniformes"}
CLASS_CATEGORIES = {"Echinoidea": "sea urchin", "Holothuroidea": "sea cucumber", "Scyphozoa": "jellyfish",
                    "Polychaeta": "worm", "Ascidiacea": "sea squirt", "Merostomata": "horseshoe crab",
                    "Malacostraca": "crustacean", "Thecostraca": "crustacean", "Bivalvia": "mollusk", "Gastropoda": "mollusk"}
TURTLE_FAMILIES = {"Cheloniidae", "Dermochelyidae"}
GROUP_NOUNS = {"fish": "fish", "shark": "shark", "ray": "ray", "eel": "eel", "seahorse": "seahorse", "crustacean": "crustacean",
               "mollusk": "mollusk", "octopus": "octopus", "squid": "squid", "turtle": "sea turtle", "sea cucumber": "sea cucumber",
               "sea urchin": "sea urchin", "jellyfish": "jellyfish", "worm": "marine worm", "sea squirt": "sea squirt",
               "horseshoe crab": "horseshoe crab"}
LIFESTYLE = {"reef-associated": "reef-associated", "demersal": "bottom-living", "benthic": "bottom-living",
             "bathydemersal": "deep bottom-living", "benthopelagic": "near-bottom", "pelagic-neritic": "coastal open-water",
             "pelagic-oceanic": "open-ocean", "pelagic": "open-water", "bathypelagic": "deep open-water", "sessile": "attached"}
HABITAT_PHRASES = {"reef": "coral reefs", "lagoon": "lagoons", "sand": "sand", "rubble": "rubble", "seagrass": "seagrass beds",
                   "mangrove": "mangroves", "wall": "drop-offs", "open water": "open water", "anemone": "anemones"}
# FAO major fishing areas -> controlled vocabulary regions (CatalogueVocabulary.regions).
FAO_REGIONS = {21: {"atlantic", "western atlantic"}, 31: {"atlantic", "western atlantic"}, 41: {"atlantic", "western atlantic"},
               27: {"atlantic"}, 34: {"atlantic"}, 47: {"atlantic"},
               51: {"indian", "indo-pacific"}, 57: {"indian", "indo-pacific"},
               61: {"pacific", "indo-pacific"}, 71: {"pacific", "indo-pacific"}, 81: {"pacific", "indo-pacific"},
               67: {"pacific"}, 77: {"pacific"}, 87: {"pacific"}}
MARINE_FAO_AREAS = set(FAO_REGIONS) | {18, 37, 48, 58, 88}
# FishBase country names (countref.PAESE) -> vocabulary regions.
COUNTRY_REGIONS = {
    "Bahamas": {"bahamas", "caribbean"}, "Belize": {"belize", "caribbean"}, "Bermuda": {"bermuda"},
    "Virgin Is. (GB)": {"british virgin islands", "caribbean"}, "Virgin Is. (US)": {"us virgin islands", "caribbean"},
    "Cayman Is.": {"cayman islands", "caribbean"}, "Dominican Rep.": {"dominican republic", "caribbean"},
    "Jamaica": {"jamaica", "caribbean"}, "Curacao": {"curacao", "caribbean"}, "Aruba": {"aruba", "caribbean"},
    "Puerto Rico": {"puerto rico", "caribbean"}, "Turks Caicos Is": {"turks and caicos", "caribbean"},
    "Cuba": {"caribbean"}, "Haiti": {"caribbean"}, "Barbados": {"caribbean"}, "Grenada": {"caribbean"},
    "Trinidad Tobago": {"caribbean"}, "Martinique": {"caribbean"}, "Guadeloupe": {"caribbean"},
    "Antigua Barbuda": {"caribbean"}, "Saint Lucia": {"caribbean"}, "Dominica": {"caribbean"},
    "Fiji": {"fiji"}, "Hawaii": {"hawaii"},
}
OCEAN_NAMES = ("Atlantic", "Indian", "Pacific", "Arctic", "Southern")
# Structured morphdat appearance codes -> markings. Barbels come only from BarbelsNo:
# text often says "barbels absent".
STRIPE_CODES = ("HorStripesTTI", "VerStripesTTI", "DiaStripesTTI", "CurStripesTTI")
SPOT_CODES = {"one spot only", "more than one spot"}
MARGIN_CODES = ("DorsalFinII", "CaudalFinII", "AnalFinII")
STAGE_LABELS = {"juvenile": "Juvenile", "male": "Male", "female": "Female"}
BODY_SHAPE_I = {"fusiform / normal": "torpedo", "elongated": "elongated", "eel-like": "serpentine", "short and / or deep": "compressed"}
BODY_SHAPE_II = {"compressed": "compressed", "oval": "oval", "circular": "round", "flattened": "flat"}
ECOLOGY_HABITATS = {"CoralReefs": "reef", "Sand": "sand", "Rubble": "rubble", "SeaGrassBeds": "seagrass", "Mangroves": "mangrove",
                    "Lagoons": "lagoon", "DropOffs": "wall"}
HAZARDS = {"venomous": "Venomous: avoid touching.", "traumatogenic": "Can injure if handled.",
           "reports of ciguatera poisoning": "Ciguatera poisoning has been reported from eating it.",
           "poisonous to eat": "Poisonous to eat."}
# Fields a source can supply; dataSources.reviewedFields lists the ones it did.
SOURCED_FIELDS = ("commonName", "aliases", "scientificName", "taxonomy", "categories", "colors", "markings", "bodyShapes",
                  "habitats", "behaviors", "regions", "subregions", "maximumSizeCentimeters", "measurements",
                  "minimumDepthMeters", "maximumDepthMeters", "summary", "distinguishingFeatures", "typicalHabitat",
                  "geographicRange", "cautions", "tailShape", "mouthAndHeadShape", "finAndSpineClues", "similarSpecies",
                  "appearanceVariants")


def truthy(value):
    return value not in (None, 0, "", False)


def number(value):
    return f"{value:g}"


def and_list(items):
    items = list(items)
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1] if items else ""


def article(word):
    return "An" if word[:1].lower() in "aeiou" else "A"


def category_from_taxonomy(taxonomic_class, order, family, genus):
    """The animal group from the source taxonomy, or None when it doesn't settle one."""
    if family in TURTLE_FAMILIES:
        return "turtle"
    if taxonomic_class == "Elasmobranchii":
        return "ray" if order in RAY_ORDERS else "shark"
    if taxonomic_class in ("Teleostei", "Actinopteri", "Actinopterygii"):
        if order == "Anguilliformes":
            return "eel"
        return "seahorse" if genus == "Hippocampus" else "fish"
    if taxonomic_class == "Cephalopoda":
        return {"Octopoda": "octopus", "Myopsida": "squid", "Oegopsida": "squid"}.get(order, "mollusk")
    return CLASS_CATEGORIES.get(taxonomic_class)


def regions_for(fao_codes, countries):
    regions = set()
    for code in fao_codes:
        regions |= FAO_REGIONS.get(code, set())
    for name in countries:
        regions |= COUNTRY_REGIONS.get(name, set())
    if "curacao" in regions:
        regions.add("curaçao")
    return sorted(regions)


def readable_fao(name):
    """'Pacific, Western Central' -> 'Western Central Pacific'."""
    ocean, _, part = name.partition(", ")
    return f"{part} {ocean}" if part else name


def basins_phrase(basins):
    oceans = [b for b in OCEAN_NAMES if b in basins]
    parts = []
    if oceans:
        parts.append("the " + and_list(oceans) + (" Ocean" if len(oceans) == 1 else " Oceans"))
    if "Mediterranean and Black Sea" in basins:
        parts.append("the Mediterranean and Black Sea")
    return " and ".join(parts)


def fin_clues(m):
    def span(lo, hi):
        lo, hi = (int(v) if v not in (None, 0) else None for v in (lo, hi))
        if lo is None and hi is None:
            return None
        return str(lo or hi) if lo in (None, hi) or hi is None else f"{lo}–{hi}"
    clues = []
    for fin, spines, rays in (("Dorsal", ("DorsalSpinesMin", "DorsalSpinesMax"), ("DorsalSoftRaysMin", "DorsalSoftRaysMax")),
                              ("Anal", ("AnalFinSpinesMin", "AnalFinSpinesMax"), ("Araymin", "Araymax"))):
        s, r = span(*(m.get(k) for k in spines)), span(*(m.get(k) for k in rays))
        parts = ([f"{s} spines"] if s else []) + ([f"{r} soft rays"] if r else [])
        if parts:
            clues.append(f"{fin} fin: " + ", ".join(parts))
    return clues


def summary_text(noun, lifestyle, family, family_common, basins, length, length_type, shallow, deep):
    """Short original summary assembled from source facts."""
    lead = f"{lifestyle} {noun}" if lifestyle else noun
    first = f"{article(lead)} {lead}"
    if family:
        first += f" of the family {family}" + (f" ({family_common})" if family_common else "")
    if basins:
        first += f", recorded from {basins}"
    sentences = [first + "."]
    if length:
        sentences.append(f"Reaches about {number(length)} cm" + (f" {LENGTH_WORDS[length_type]}" if length_type else "") + ".")
    if shallow is not None and deep is not None:
        sentences.append(f"Recorded at depths of {number(shallow)}–{number(deep)} m.")
    return " ".join(sentences)


def feature_list(colors, markings, shapes, tail, mouth, fins, family, genus):
    """Short original distinguishing features, each one source fact."""
    features = []
    if colors: features.append(f"Colours: {and_list(colors)}.")
    if markings: features.append(f"Markings: {and_list(markings)}.")
    if shapes: features.append(f"Body shape: {and_list(shapes)}.")
    if tail: features.append(f"Tail: {tail}.")
    if mouth: features.append(f"Mouth: {and_list([m.removesuffix(' mouth') for m in mouth])}.")
    features += [f + "." for f in fins]
    return features or ([f"Family: {family}."] if family else [f"Genus: {genus}."])


def habitat_text(lifestyle, habitats, shallow, deep):
    parts = [lifestyle[:1].upper() + lifestyle[1:]] if lifestyle else []
    places = [HABITAT_PHRASES[h] for h in ("reef", "lagoon", "seagrass", "mangrove", "sand", "rubble", "wall", "open water", "anemone") if h in habitats]
    if places:
        parts.append(and_list(places))
    if shallow is not None and deep is not None:
        parts.append(f"{number(shallow)}–{number(deep)} m")
    return "; ".join(parts) + "." if parts else ""


def distribution_text(basins, fao_names, country_count):
    parts = []
    if basins:
        place = basins.removeprefix("the ")
        parts.append(place[:1].upper() + place[1:])
    if fao_names:
        parts.append("FAO areas: " + "; ".join(readable_fao(n) for n in fao_names))
    if country_count:
        parts.append(f"Recorded from {country_count} {'country or territory' if country_count == 1 else 'countries and territories'}")
    return ". ".join(parts) + "." if parts else ""


def trait_fields(src):
    """The source text fields traits are read from."""
    sp, morph, ecology = src["species"], src.get("morphdat") or {}, src.get("ecology", [])
    return {"morphdat.AddChars": morph.get("AddChars"), "morphdat.RemarkSex": morph.get("RemarkSex"),
            "species.Comments": sp.get("Comments"),
            "ecology.AddRems": " ".join(str(e.get("AddRems") or "") for e in ecology),
            "ecology.AssociationsWith": " ".join(str(e.get("AssociationsWith") or "") for e in ecology)}


def trait_signature(extracted):
    main = extracted["main"]
    return (tuple(sorted(main.colors)), tuple(sorted(main.markings)), tuple(sorted(main.habitats)), tuple(sorted(main.behaviors)),
            tuple(main.head), tuple(main.fins), tuple(main.features), tuple(main.tail_shapes),
            tuple(sorted((k, tuple(sorted(v.colors)), tuple(sorted(v.markings)), tuple(v.head + v.fins + v.features)) for k, v in extracted["variants"].items())),
            tuple(extracted["flags"]))


def rule_effects(src):
    """Which extraction rules change this record's traits (each rule switched off in turn)."""
    fields = trait_fields(src)
    full = trait_signature(traits.extract(fields))
    return [rule for rule in sorted(traits.RULES) if trait_signature(traits.extract(fields, traits.RULES - {rule})) != full]


def build_profile(entry, src, similar_targets=None):
    """entry: a resolution row with id and categories. src: this species' source facts.
    similar_targets: {(server, SpecCode): (uuid, accepted name)} of records in the pack.
    Returns (profile, source passages for the verbatim check, {"flags", "trace"})."""
    sp, fam, morph = src["species"], src.get("family") or {}, src.get("morphdat") or {}
    server, code = entry["server"], int(entry["specCode"])
    accepted = entry["acceptedName"]
    genus = accepted.split(" ")[0]
    english = [n for n in src.get("english_names", []) if n]
    common = (sp.get("FBname") or (english[0] if english else "") or accepted).strip()
    aliases = []
    for name in english + ([entry["inputName"]] if entry["resolution"] == "synonym" else []):
        if name.strip().lower() not in {common.lower(), accepted.lower()} and name.strip().lower() not in {a.lower() for a in aliases}:
            aliases.append(name.strip())
    aliases = aliases[:6]

    demers = (sp.get("DemersPelag") or "").strip()
    lifestyle = LIFESTYLE.get(demers, "")
    shapes = sorted({BODY_SHAPE_I.get((sp.get("BodyShapeI") or "").strip()), BODY_SHAPE_II.get((morph.get("BodyShapeII") or "").strip())} - {None})
    fins = fin_clues(morph)
    ecology = src.get("ecology", [])
    extracted = traits.extract(trait_fields(src))
    found, flags = extracted["main"], list(extracted["flags"])
    used = {t["source"] for t in extracted["trace"] if "value" in t}
    trace = list(extracted["trace"])
    def structured(kind, value, field):
        trace.append({"target": "main", "kind": kind, "value": value, "source": field})
        used.add(field)
    habitats = {h for col, h in ECOLOGY_HABITATS.items() if any(truthy(e.get(col)) for e in ecology)}
    if demers == "reef-associated":
        habitats.add("reef")
    if demers.startswith("pelagic"):
        habitats.add("open water")
    shallow, deep = sp.get("DepthRangeShallow"), sp.get("DepthRangeDeep")
    depth_ok = shallow is not None and deep is not None and 0 <= shallow <= deep
    shallow, deep = (round(float(shallow), 2), round(float(deep), 2)) if depth_ok else (None, None)
    if shallow is not None and shallow <= 10:
        habitats.add("shallow")
    if shallow is not None and shallow >= 30:
        habitats.add("deep")
    habitats |= found.habitats
    behaviors = set(found.behaviors)
    juvenile_only = lambda e, col: "juv" in str(e.get(col) or "").lower() and "adult" not in str(e.get(col) or "").lower()
    if any(truthy(e.get("Schooling")) and not juvenile_only(e, "SchoolingLifestage") for e in ecology): behaviors.add("schooling")
    if any(truthy(e.get("Solitary")) for e in ecology): behaviors.add("solitary")
    if any(truthy(e.get("Burrows")) for e in ecology): behaviors.add("burrowing")
    if any((e.get("FeedingType") or "") == "grazing on aquatic plants" for e in ecology): behaviors.add("grazing")
    if "anemone association" in behaviors:
        habitats.add("anemone")
    features = list(found.features)
    if any(str(e.get("Circadian1") or "").strip() == "nocturnal" for e in ecology) and "Active at night" not in features:
        features.append("Active at night"); structured("features", "Active at night", "ecology.Circadian1")
    colors = sorted(found.colors)
    markings = set(found.markings)
    if (morph.get("BarbelsNo") or 0) > 0:
        markings.add("barbels"); structured("markings", "barbels", "morphdat.BarbelsNo")
    for field in STRIPE_CODES:
        if (morph.get(field) or "").strip() == "present":
            markings.add("stripes"); structured("markings", "stripes", f"morphdat.{field}")
    if (morph.get("SpotsTTI") or "").strip() in SPOT_CODES:
        markings.add("spots"); structured("markings", "spots", "morphdat.SpotsTTI")
    for field in MARGIN_CODES:
        if (morph.get(field) or "").strip() == "colored margin":
            markings.add("fin edge"); structured("markings", "fin edge", f"morphdat.{field}")
    coded_tail = (morph.get("CShape") or "").replace("more or less ", "").strip()
    coded_tail = coded_tail if coded_tail and not coded_tail.startswith("other") else None
    text_tail = found.tail_shapes[0] if found.tail_shapes else None
    if coded_tail and text_tail and coded_tail != text_tail:
        tail = None  # the coded shape and the description disagree: assert neither
        flags.append("trait_ambiguous:tailShape")
    else:
        tail = coded_tail or text_tail
    mouth = []
    position = (morph.get("PosofMouth") or "").strip()
    if position:
        mouth.append(("inferior" if position.startswith("sub-terminal") else position) + " mouth")
    mouth_type = {"tube-like": "tube-like mouth", "sucker-like": "sucker-like mouth", "clearly protrusible": "protrusible mouth"}.get((morph.get("TypeofMouth") or "").strip())
    if mouth_type:
        mouth.append(mouth_type)
    mouth += [h for h in found.head if h not in mouth]
    fins += [f for f in found.fins if f not in fins]
    variants = []
    for stage in ("juvenile", "male", "female"):
        v = extracted["variants"].get(stage)
        if not v:
            continue
        notes = v.head + v.fins + v.features + sorted(v.behaviors) + [f"Found on {h}" if h in ("sand", "rubble") else f"Found in {h}s" if h in ("lagoon", "mangrove", "wreck") else f"Found with {h}s" if h == "anemone" else f"Found in {h}" for h in sorted(v.habitats)]
        parts = ([and_list(sorted(v.colors))] if v.colors else []) + ([and_list(sorted(v.markings))] if v.markings else []) + [n[:1].lower() + n[1:] for n in notes]
        variants.append({"id": stage, "lifeStage": stage, "colors": sorted(v.colors), "markings": sorted(v.markings), "bodyShapes": [],
                         "minimumSizeCentimeters": None, "maximumSizeCentimeters": None,
                         "description": f"{STAGE_LABELS[stage]}: " + "; ".join(parts) + ".", "distinguishingFeatures": notes})
    length, ltype = sp.get("Length"), LENGTH_TYPES.get((sp.get("LTypeMaxM") or "").strip())
    length = round(float(length), 2) if length else None
    dist = src.get("distribution") or {}
    fao_codes = [a["code"] for a in dist.get("faoAreas", []) if a["counts"] and a["code"] in MARINE_FAO_AREAS]
    fao_names = [src["fao_area_names"][str(c)] for c in fao_codes if src["fao_area_names"].get(str(c))]
    countries = [src["country_names"].get(c["code"], {}).get("name", "") for c in dist.get("countries", []) if c["counts"]]
    basins = basins_phrase(dist.get("oceanBasins", []))
    noun = GROUP_NOUNS.get((entry["categories"] or [""])[0], "marine animal")
    similar = []
    for other in (morph.get("SimilarSpecies1"), morph.get("SimilarSpecies2")):
        target = (similar_targets or {}).get((server, other))
        if target and target[0] != entry["id"] and target[0] not in {s["speciesID"] for s in similar}:
            similar.append({"speciesID": target[0], "distinguishingText": f"Listed as similar in {SOURCES[server][0]}; compare with {target[1]} before confirming."})
    name, url = SOURCES[server]
    profile = {
        "id": entry["id"], "commonName": common, "scientificName": accepted, "aliases": aliases,
        "categories": entry["categories"], "colors": colors, "markings": sorted(markings),
        "bodyShapes": shapes, "habitats": sorted(habitats),
        "regions": regions_for(fao_codes, countries), "behaviors": sorted(behaviors), "keywords": [],
        "minimumSizeCentimeters": None, "maximumSizeCentimeters": length,
        "minimumDepthMeters": shallow, "maximumDepthMeters": deep,
        "summary": summary_text(noun, lifestyle, fam.get("Family"), (fam.get("CommonName") or "").strip().lower(), basins, length, ltype, shallow, deep),
        "distinguishingFeatures": feature_list(colors, sorted(markings), shapes, tail, mouth, fins, fam.get("Family"), genus) + [f + "." for f in features],
        "typicalHabitat": habitat_text(lifestyle, habitats, shallow, deep),
        "geographicRange": distribution_text(basins, fao_names, len([c for c in countries if c])),
        "cautions": [HAZARDS[h] for h in [(sp.get("Dangerous") or "").strip()] if h in HAZARDS],
        "imageAssetName": None, "regionalOccurrence": "unknown", "regionalOccurrenceNotes": None,
        "subregions": [readable_fao(n) for n in fao_names], "appearanceVariants": variants, "similarSpecies": similar, "bundledImage": None,
        "dataSources": [{
            "stableSourceID": f"{name}:SpecCode:{code}", "sourceName": f"{name} ({src['release']})",
            "sourceURL": url.format(code), "citationReference": src.get("main_ref"), "reviewedFields": [],
            "accessedDate": ACCESSED, "sourceLicense": LICENSE}],
        "review": {"status": "draft", "reviewerNotes": f"Generated from {name} {src['release']} by Tools/FishBaseIntake/build.py; awaiting batch review.",
                   "reviewDate": None, "verifiedBy": None},
        "taxonomy": {"wormsAphiaID": None, "scientificNameAuthority": sp.get("Author"), "taxonomicClass": fam.get("Class"),
                     "order": fam.get("Order"), "family": fam.get("Family"), "genus": genus,
                     "acceptedScientificName": accepted, "sourceScientificName": entry["inputName"]},
        "measurements": ({"typicalObservedMinimumCentimeters": None, "typicalObservedMaximumCentimeters": None,
                          "maximumRecordedCentimeters": length, "type": ltype} if length and ltype else None),
        "tailShape": tail, "mouthAndHeadShape": mouth, "finAndSpineClues": fins,
    }
    profile["dataSources"][0]["reviewedFields"] = [f for f in SOURCED_FIELDS if profile[f] not in (None, "", [], {})]
    profile["dataSources"][0]["sourceFields"] = sorted(used)
    source_passages = [t for t in (sp.get("Comments"), morph.get("AddChars"), morph.get("RemarkSex"), src.get("range_text")) if t]
    return profile, source_passages, {"flags": sorted(set(flags)), "trace": trace}


def enforce_unique_names(profiles, reserved_names):
    """Common names must be unique and aliases may not equal another record's names."""
    norm = lambda s: " ".join(s.lower().split())
    counts = {}
    for p in profiles:
        counts[norm(p["commonName"])] = counts.get(norm(p["commonName"]), 0) + 1
    renamed = []
    for p in profiles:
        if counts[norm(p["commonName"])] > 1 or norm(p["commonName"]) in reserved_names:
            p["commonName"] = f"{p['commonName']} ({p['scientificName']})"
            renamed.append(p["id"])
    canonical = set(reserved_names)
    for p in profiles:
        canonical |= {norm(p["commonName"]), norm(p["scientificName"])}
    for p in profiles:
        own = {norm(p["commonName"]), norm(p["scientificName"])}
        p["aliases"] = [a for a in p["aliases"] if norm(a) in own or norm(a) not in canonical]
    return renamed


def load_sources(manifest, cache, offline, wanted, staged):
    """Index the pinned tables and the staged distribution by (server, SpecCode)."""
    optional = ("Circadian1", "SchoolingLifestage", "RemarkSex", "AddRems", *STRIPE_CODES, "SpotsTTI", *MARGIN_CODES)
    read = lambda sv, t, cols: fetch.read_table(manifest, cache, sv, t, cols, offline, optional)
    out = {}
    for sv in sorted(manifest["servers"]):
        codes = {code for server, code in wanted if server == sv}
        release = manifest["servers"][sv]["release"]
        families = {r["FamCode"]: r for r in read(sv, "families", ["FamCode", "Family", "Order", "Class", "CommonName"])}
        refs = {r["RefNo"]: r for r in read(sv, "refrens", ["RefNo", "Author", "Year", "ShortCitation"])}
        def per_species(rows, key="SpecCode"):
            grouped = {}
            for r in rows:
                if r.get(key) in codes:
                    grouped.setdefault(r[key], []).append(r)
            return grouped
        species = per_species(read(sv, "species", ["SpecCode", "FBname", "Author", "FamCode", "Length", "LTypeMaxM", "DepthRangeShallow",
                                                   "DepthRangeDeep", "DemersPelag", "BodyShapeI", "Dangerous", "Comments", "SpeciesRefNo", "Saltwater", "Brack"]))
        names = per_species(read(sv, "comnames", ["SpecCode", "ComName", "Language"]))
        ecology = per_species(read(sv, "ecology", ["SpecCode", *ECOLOGY_HABITATS, "Schooling", "SchoolingLifestage", "Solitary", "Burrows",
                                                   "FeedingType", "AssociationsWith", "AddRems", "Circadian1"]))
        morph = per_species(read(sv, "morphdat", ["Speccode", "AddChars", "RemarkSex", "BodyShapeII", "CShape", "TypeofMouth", "PosofMouth",
                                                  *STRIPE_CODES, "SpotsTTI", *MARGIN_CODES,
                                                  "DorsalSpinesMin", "DorsalSpinesMax", "DorsalSoftRaysMin", "DorsalSoftRaysMax",
                                                  "AnalFinSpinesMin", "AnalFinSpinesMax", "Araymin", "Araymax", "BarbelsNo",
                                                  "SimilarSpecies1", "SimilarSpecies2"]), key="Speccode")
        stocks = per_species(read(sv, "stocks", ["SpecCode", "StockDefs", "Level"]))
        for code in codes:
            sp = (species.get(code) or [{}])[0]
            english = sorted({r["ComName"].strip() for r in names.get(code, []) if r.get("Language") == "English" and r.get("ComName")},
                             key=lambda n: (n.lower() != (sp.get("FBname") or "").lower(), n.lower(), n))
            stock_rows = sorted(stocks.get(code, []), key=lambda r: (r.get("Level") != "species in general",))
            ref = refs.get(sp.get("SpeciesRefNo")) or {}
            out[(sv, code)] = {
                "release": release, "species": sp, "family": families.get(sp.get("FamCode")),
                "english_names": english, "ecology": ecology.get(code, []), "morphdat": (morph.get(code) or [None])[0],
                "range_text": next((r["StockDefs"] for r in stock_rows if r.get("StockDefs")), ""),
                "distribution": staged["species"].get(f"{sv}:{code}"),
                "fao_area_names": staged["faoAreaNames"], "country_names": staged["countries"],
                "main_ref": (ref.get("ShortCitation") or " ".join(filter(None, [str(ref.get("Author") or ""), str(ref.get("Year") or "")])).strip()
                             or (f"{SOURCES[sv][0]} reference {sp['SpeciesRefNo']}" if sp.get("SpeciesRefNo") else None)),
            }
    return out


def lives_in_sea(species_row):
    """Marine or brackish per the source; freshwater-only species are out of scope."""
    return truthy(species_row.get("Saltwater")) or truthy(species_row.get("Brack"))


def select_entries(plan_rows, resolution_rows, candidate_rows):
    """One record per accepted taxon, under the UUID the merge plan keeps.

    The 8 Caribbean records stay as they are, so a taxon kept by a Caribbean record is
    not rebuilt. Retired, unresolved and conflicted inputs are never built."""
    categories = {r["candidateID"]: r["proposedAppCategory"] for r in candidate_rows}
    resolution = {(r["inputKind"], r["inputID"]): r for r in resolution_rows}
    entries = []
    for plan in plan_rows:
        if plan["role"] != "keep" or plan["pack"] == "Caribbean":
            continue
        row = resolution[(plan["inputKind"], plan["inputID"])]
        entries.append(dict(row, id=plan["plannedUUID"], candidateCategory=categories.get(plan["inputID"])))
    return entries


def batch_text(batch):
    return "[\n" + ",\n".join(json.dumps(p, ensure_ascii=False) for p in batch) + "\n]\n"


def write_batches(profiles, drafts, only=None):
    """Write review batches resumably: an existing batch with identical content is left
    alone; changed batches are replaced atomically. Returns {batch name: action}."""
    drafts.mkdir(parents=True, exist_ok=True)
    actions, names = {}, []
    for i in range(0, len(profiles), BATCH_SIZE):
        name = f"batch-{i // BATCH_SIZE + 1:02d}"
        names.append(name)
        if only is not None and name != f"batch-{only:02d}":
            continue
        text = batch_text(profiles[i:i + BATCH_SIZE])
        path = drafts / f"{name}.json"
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == hashlib.sha256(text.encode()).hexdigest():
            actions[name] = "unchanged"
            continue
        temp = path.with_suffix(".json.tmp")
        temp.write_text(text)
        temp.replace(path)
        actions[name] = "written"
    if only is None:
        for stale in drafts.glob("batch-*.json"):
            if stale.stem not in names:
                stale.unlink()
                actions[stale.stem] = "removed"
    manifest = {"builderVersion": BUILDER_VERSION, "batchSize": BATCH_SIZE,
                "batches": {n: hashlib.sha256((drafts / f"{n}.json").read_bytes()).hexdigest() for n in names if (drafts / f"{n}.json").exists()}}
    (drafts / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return actions


def coverage(profiles):
    filled = lambda f: sum(1 for p in profiles if p[f] not in (None, "", [], {}))
    fields = ("commonName", "aliases", "categories", "colors", "markings", "bodyShapes", "habitats", "behaviors", "regions",
              "maximumSizeCentimeters", "measurements", "maximumDepthMeters", "summary", "distinguishingFeatures",
              "typicalHabitat", "geographicRange", "cautions", "tailShape", "mouthAndHeadShape", "finAndSpineClues", "similarSpecies",
              "appearanceVariants")
    total = len(profiles) or 1
    return {f: round(filled(f) / total, 4) for f in fields}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", default=fetch.DEFAULT_CACHE)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--output", default=REPO / "Data/GlobalMarine/FishBase")
    parser.add_argument("--batch", type=int, help="write only this batch number (resume or rework one batch)")
    args = parser.parse_args(argv)
    output = Path(args.output)
    plan_report = json.loads((output / "MergePlanReport.json").read_text())
    if plan_report["conflicts"]:
        raise SystemExit("The merge plan has conflicts; resolve them before building (see MergePlanReport.json).")
    resolution = list(csv.DictReader(open(output / "NameResolution.csv", newline="")))
    candidates = list(csv.DictReader(open(REPO / "Data/GlobalMarine/Expansion4000_CandidateQueue.csv", newline="")))
    plan_rows = list(csv.DictReader(open(output / "MergePlan.csv", newline="")))
    manifest = fetch.load_manifest()
    staged = distribution.read_snapshot(output / "Distribution.json", distribution.source_of(manifest))  # fails closed
    caribbean = json.loads((REPO / "DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json").read_text())
    tropical_ids = {r["id"] for r in json.loads((REPO / "DiveID/Resources/IdentificationPacks/TropicalPacific/Creatures.json").read_text())}
    entries = select_entries(plan_rows, resolution, candidates)
    sources = load_sources(manifest, args.cache, args.offline, {(e["server"], int(e["specCode"])) for e in entries}, staged)
    kept = [e for e in entries if lives_in_sea(sources[(e["server"], int(e["specCode"]))]["species"])]
    freshwater_only = sorted(e["acceptedName"] for e in entries if e not in kept)
    targets = {(e["server"], int(e["specCode"])): (e["id"], e["acceptedName"]) for e in kept}
    targets.update({(r["taxonKey"].split(":")[0], int(r["taxonKey"].split(":")[1])): (r["plannedUUID"], r["acceptedName"])
                    for r in plan_rows if r["role"] == "keep" and r["pack"] == "Caribbean"})
    profiles, passages, disagreements, extra_flags, clue_trace, effects = [], {}, [], {}, {}, {}
    previous = {}
    for path in sorted((output / "Drafts").glob("batch-*.json")):
        previous.update({r["id"]: r for r in json.loads(path.read_text())})
    for e in kept:
        src = sources[(e["server"], int(e["specCode"]))]
        fam = src.get("family") or {}
        derived = category_from_taxonomy(fam.get("Class"), fam.get("Order"), fam.get("Family"), e["acceptedName"].split(" ")[0])
        queued = e["candidateCategory"] if e["candidateCategory"] not in (None, "", "needs_taxon_group") else None
        e["categories"] = [derived or queued] if (derived or queued) else []
        if derived and queued and derived != queued:
            disagreements.append(f"{e['acceptedName']}: taxonomy {derived}, queue {queued}")
        profile, source_passages, info = build_profile(e, src, targets)
        profiles.append(profile)
        passages[profile["id"]] = source_passages
        extra_flags[profile["id"]] = info["flags"]
        clue_trace[profile["id"]] = info["trace"]
        for rule in rule_effects(src):
            effects.setdefault(rule, []).append(profile["id"])
    reserved = {" ".join(n.lower().split()) for r in caribbean for n in (r["commonName"], r["scientificName"])}
    renamed = enforce_unique_names(profiles, reserved)
    actions = write_batches(profiles, output / "Drafts", args.batch)
    risk = catalogue_validation.assess_risk(profiles, passages, [r["commonName"] for r in caribbean], extra_flags)
    for i, p in enumerate(profiles):
        risk["records"][p["id"]]["batch"] = i // BATCH_SIZE + 1
    report = {
        "builderVersion": BUILDER_VERSION, "records": len(profiles), "batches": (len(profiles) + BATCH_SIZE - 1) // BATCH_SIZE,
        "batchActions": actions,
        "rebuiltTropicalPacific": sum(p["id"] in tropical_ids for p in profiles),
        "fromCandidates": sum(p["id"] not in tropical_ids for p in profiles),
        "keptUnchangedCaribbean": len(caribbean),
        "excludedFreshwaterOnly": freshwater_only,
        "commonNamesDisambiguated": len(renamed),
        "categoryFromQueueBecauseTaxonomyUnmapped": sum(1 for e in kept if e["categories"] and category_from_taxonomy(
            *(lambda f: (f.get("Class"), f.get("Order"), f.get("Family")))(sources[(e["server"], int(e["specCode"]))].get("family") or {}),
            e["acceptedName"].split(" ")[0]) is None),
        "categoryDisagreementsWithQueue": disagreements,
        "fieldCoverage": coverage(profiles),
        "recordsChangedByRule": {rule: len(effects.get(rule, [])) for rule in sorted(traits.RULES)},
        "recordsWithAppearanceVariants": {stage: sum(any(v["lifeStage"] == stage for v in p["appearanceVariants"]) for p in profiles)
                                          for stage in ("juvenile", "male", "female")},
        "recordsWithTraitAmbiguousFlag": sum(any(f.startswith("trait_ambiguous") for f in fl) for fl in extra_flags.values()),
        "changedSincePreviousBuild": {f: sum(1 for p in profiles if p["id"] in previous and previous[p["id"]].get(f) != p.get(f))
                                      for f in ("colors", "markings", "habitats", "behaviors", "tailShape", "mouthAndHeadShape",
                                                "finAndSpineClues", "appearanceVariants", "distinguishingFeatures")},
        "categories": dict(sorted({c: sum(c in p["categories"] for p in profiles) for p in profiles for c in p["categories"]}.items())),
        "risk": {k: v for k, v in risk.items() if k != "records"},
    }
    (output / "BuildReport.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    (output / "RiskReport.json").write_text(json.dumps(risk, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    (output / "ClueTrace.json").write_text(json.dumps({"builderVersion": BUILDER_VERSION, "records": clue_trace},
                                                      ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("categoryDisagreementsWithQueue", "batchActions")}, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
