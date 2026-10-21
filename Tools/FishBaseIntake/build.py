"""Build draft LocalSpeciesProfile records from the pinned FishBase/SeaLifeBase release.

Input: NameResolution.csv (resolve.py) plus the pinned tables. Every resolved,
non-duplicate candidate and every resolved Tropical Pacific record becomes one
draft record. The 8 Caribbean records are kept as they are (2 are human-verified)
and only reserve their names. Output: review batches of 250 records,
Data/GlobalMarine/FishBase/Drafts/batch-NN.json, plus BuildReport.json.

Every field is mapped deterministically from the source tables (see
Docs/GlobalMarine4000ActivationPlan.md §4). Text is adapted only by removing
FishBase reference markers and picking whole sentences. Colours and markings are
extracted from the diagnosis text and are reviewed with each batch.
"""
import argparse
import csv
import json
import re
import sys
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
import fetch  # noqa: E402

BATCH_SIZE = 250
# The same namespace Tools/GlobalMarineImport uses, so candidate identities stay stable.
CANDIDATE_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://github.com/bryce496913/Dive-ID/global-marine")
ACCESSED = "2026-10-21T00:00:00Z"
LICENSE = "CC BY-NC 4.0"
SOURCES = {
    "fb": ("FishBase", "https://www.fishbase.se/summary/SpeciesSummary.php?ID={}"),
    "slb": ("SeaLifeBase", "https://www.sealifebase.se/summary/SpeciesSummary.php?ID={}"),
}
EXCLUDED_STATUSES = {"questionable", "misidentification", "error", "not established", "extirpated"}

LENGTH_TYPES = {"TL": "totalLength", "SL": "standardLength", "FL": "forkLength", "WD": "discWidth",
                "DL": "discLength", "CL": "carapaceLength", "CW": "carapaceWidth", "SHL": "shellLength",
                "ML": "mantleLength", "BL": "bodyLength"}
FAMILY_CATEGORIES = {
    "sea cucumber": {"Holothuriidae", "Stichopodidae", "Cucumariidae", "Phyllophoridae", "Synaptidae"},
    "sea urchin": {"Strongylocentrotidae", "Echinidae", "Arbaciidae", "Toxopneustidae", "Diadematidae", "Echinometridae"},
    "jellyfish": {"Pelagiidae", "Ulmaridae", "Stomolophidae", "Cassiopeidae", "Rhizostomatidae", "Cyaneidae"},
    "worm": {"Arenicolidae", "Onuphidae", "Glyceridae", "Nereididae", "Lumbrineridae", "Urechidae", "Sabellidae", "Serpulidae", "Amphinomidae"},
    "horseshoe crab": {"Limulidae"},
    "sea squirt": {"Pyuridae", "Ascidiidae", "Styelidae", "Didemnidae"},
}
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
COLOR_TERMS = {"blue": ["blue", "bluish", "navy", "turquoise", "cyan"], "yellow": ["yellow", "yellowish", "gold", "golden"],
               "red": ["red", "reddish", "scarlet", "crimson"], "white": ["white", "whitish"], "black": ["black", "blackish"],
               "brown": ["brown", "brownish"], "olive": ["olive"], "orange": ["orange", "orangish"],
               "silver": ["silver", "silvery"], "green": ["green", "greenish"], "gray": ["gray", "grey", "grayish", "greyish"]}
MARKING_TERMS = {"spots": ["spot", "spots", "spotted", "dots", "dotted", "ocellus", "ocelli"],
                 "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars", "barred"],
                 "patches": ["patch", "patches", "blotch", "blotches"], "saddles": ["saddle", "saddles"],
                 "eye stripe": ["eye stripe", "stripe through the eye", "stripe through eye", "bar through the eye", "bar through eye"],
                 "beak": ["beak"]}  # barbels come only from morphdat.BarbelsNo: text often says "barbels absent"
BODY_SHAPE_I = {"fusiform / normal": "torpedo", "elongated": "elongated", "eel-like": "serpentine", "short and / or deep": "compressed"}
BODY_SHAPE_II = {"compressed": "compressed", "oval": "oval", "circular": "round", "flattened": "flat"}
ECOLOGY_HABITATS = {"CoralReefs": "reef", "Sand": "sand", "Rubble": "rubble", "SeaGrassBeds": "seagrass", "Mangroves": "mangrove",
                    "Lagoons": "lagoon", "DropOffs": "wall"}
# Classes that settle a category when the candidate queue and family table don't.
CLASS_CATEGORIES = {"Echinoidea": "sea urchin", "Holothuroidea": "sea cucumber", "Scyphozoa": "jellyfish", "Polychaeta": "worm",
                    "Ascidiacea": "sea squirt", "Teleostei": "fish", "Actinopteri": "fish", "Actinopterygii": "fish"}
# Sentences about fishing, trade or husbandry don't help a diver identify an animal.
NOT_FOR_IDENTIFICATION = re.compile(r"\b(?:from|by|in|see)\s+Refs?\.\s*\d|\b(holotype|paratype|type locality|specimen|harvest|commercial|market|fisher|fishery|fisheries|aquarium|trade|price|value|caught|catch|collected|exported|consumed|eaten|food fish|bait|aquaculture|gamefish|sold)", re.I)
HAZARDS = {"venomous": "Venomous: avoid touching.", "traumatogenic": "Can injure if handled.",
           "reports of ciguatera poisoning": "Ciguatera poisoning has been reported from eating it.",
           "poisonous to eat": "Poisonous to eat."}
HTML_TAG = re.compile(r"</?[A-Za-z][A-Za-z0-9]*\s*/?>")  # only real tags: "<6 cm" is a size, not markup
HABITAT_WORDS = re.compile(r"\b(inhabit|found|occur|live|reef|lagoon|sand|rock|mud|seagrass|mangrove|depth|shallow|deep|coast|bottom|water)", re.I)


def clean(text):
    """Remove FishBase reference markers and HTML tags, and normalise whitespace."""
    text = re.sub(HTML_TAG, "", str(text or ""))
    text = re.sub(r"\s*\((?:Refs?\.|Ref)\s*[^)]*\)", "", text)
    text = re.sub(r"\s+(?:by|in|from|see)\s+Refs?\.\s*\d+(?:\s*,\s*\d+)*", "", text)
    text = re.sub(r",?\s*Refs?\.\s*\d+(?:\s*,\s*\d+)*", "", text)
    text = re.sub(r"\(\s*\)", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = re.sub(r"\s+([.,;:])", r"\1", text)
    return re.sub(r"([.;,])(?:\s*[.;,])+", r"\1", text).strip()


def sentences(text, drop=None):
    """Whole sentences, cleaned. `drop` is matched against each raw sentence, before
    cleaning removes the reference markers it may rely on."""
    raw = re.split(r"(?<=[.!?])\s+(?=[A-Z])", re.sub(r"\s+", " ", re.sub(HTML_TAG, "", str(text or ""))))
    kept = [clean(s) for s in raw if not (drop and drop.search(s))]
    return [s for s in kept if len(s) > 3]


def terms_in(text, table):
    lowered = " " + re.sub(r"[^a-z]+", " ", str(text or "").lower()) + " "
    return sorted(key for key, words in table.items() if any(f" {w} " in lowered for w in words))


def truthy(value):
    return value not in (None, 0, "", False)


def category_for(candidate_category, family, taxonomic_class=None):
    if candidate_category and candidate_category != "needs_taxon_group":
        return [candidate_category]
    for category, families in FAMILY_CATEGORIES.items():
        if family in families:
            return [category]
    return [CLASS_CATEGORIES[taxonomic_class]] if taxonomic_class in CLASS_CATEGORIES else []


def regions_for(fao_codes, countries):
    regions = set()
    for code in fao_codes:
        regions |= FAO_REGIONS.get(code, set())
    for name in countries:
        regions |= COUNTRY_REGIONS.get(name, set())
    if "curacao" in regions:
        regions.add("curaçao")
    return sorted(regions)


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


def build_profile(entry, src):
    """entry: a NameResolution row plus candidate category. src: this species' source rows."""
    sp, fam, morph = src["species"], src.get("family") or {}, src.get("morphdat") or {}
    server, code = entry["server"], int(entry["specCode"])
    accepted = entry["acceptedName"]
    english = [n for n in src.get("english_names", []) if n]
    common = (sp.get("FBname") or (english[0] if english else "") or accepted).strip()
    aliases = []
    for name in english + ([entry["inputName"]] if entry["resolution"] == "synonym" else []):
        if name.strip().lower() not in {common.lower(), accepted.lower()} and name.strip().lower() not in {a.lower() for a in aliases}:
            aliases.append(name.strip())
    aliases = aliases[:6]

    diagnosis = " ".join(filter(None, [morph.get("AddChars"), morph.get("SexColors")]))
    comment_sentences = sentences(sp.get("Comments"), drop=NOT_FOR_IDENTIFICATION)
    summary = " ".join(comment_sentences[:3])[:600].strip()
    demers = (sp.get("DemersPelag") or "").strip()
    if not summary:
        summary = f"{fam.get('Family') or 'Marine'} species" + (f"; {demers}." if demers else ".")
    features = sentences(morph.get("AddChars"), drop=NOT_FOR_IDENTIFICATION)[:4]
    shapes = sorted({BODY_SHAPE_I.get((sp.get("BodyShapeI") or "").strip()), BODY_SHAPE_II.get((morph.get("BodyShapeII") or "").strip())} - {None})
    fins = fin_clues(morph)
    if not features:
        shape = (sp.get("BodyShapeI") or "").strip()
        features = fins + ([f"Body shape: {shape}."] if shape and shape != "other" else []) or comment_sentences[:1] or [summary]
    habitats = {h for col, h in ECOLOGY_HABITATS.items() if any(truthy(e.get(col)) for e in src.get("ecology", []))}
    if demers == "reef-associated":
        habitats.add("reef")
    if demers.startswith("pelagic"):
        habitats.add("open water")
    shallow, deep = sp.get("DepthRangeShallow"), sp.get("DepthRangeDeep")
    if shallow is not None and shallow <= 10:
        habitats.add("shallow")
    if shallow is not None and shallow >= 30:
        habitats.add("deep")
    associations = " ".join(str(e.get("AssociationsWith") or "") for e in src.get("ecology", [])).lower()
    behaviors = set()
    if any(truthy(e.get("Schooling")) for e in src.get("ecology", [])): behaviors.add("schooling")
    if any(truthy(e.get("Solitary")) for e in src.get("ecology", [])): behaviors.add("solitary")
    if any(truthy(e.get("Burrows")) for e in src.get("ecology", [])): behaviors.add("burrowing")
    if any((e.get("FeedingType") or "") == "grazing on aquatic plants" for e in src.get("ecology", [])): behaviors.add("grazing")
    if "anemone" in associations:
        behaviors.add("anemone association"); habitats.add("anemone")
    markings = set(terms_in(diagnosis, MARKING_TERMS))
    if (morph.get("BarbelsNo") or 0) > 0:
        markings.add("barbels")
    tail = (morph.get("CShape") or "").replace("more or less ", "").strip()
    mouth = []
    position = (morph.get("PosofMouth") or "").strip()
    if position:
        mouth.append(("inferior" if position.startswith("sub-terminal") else position) + " mouth")
    mouth_type = {"tube-like": "tube-like mouth", "sucker-like": "sucker-like mouth", "clearly protrusible": "protrusible mouth"}.get((morph.get("TypeofMouth") or "").strip())
    if mouth_type:
        mouth.append(mouth_type)
    length, ltype = sp.get("Length"), LENGTH_TYPES.get((sp.get("LTypeMaxM") or "").strip())
    depth_ok = shallow is not None and deep is not None and 0 <= shallow <= deep
    stock_text = clean(src.get("range_text"))
    range_text = (stock_text or ", ".join(src.get("fao_names", [])) or ", ".join(src.get("countries", [])[:12])
                  or f"No range recorded in {SOURCES[server][0]}.")
    name, url = SOURCES[server]
    main_ref = src.get("main_ref")
    return {
        "id": entry["id"], "commonName": common, "scientificName": accepted, "aliases": aliases,
        "categories": entry["categories"], "colors": terms_in(diagnosis, COLOR_TERMS), "markings": sorted(markings),
        "bodyShapes": shapes, "habitats": sorted(habitats),
        "regions": regions_for(src.get("fao_codes", []), src.get("countries", [])), "behaviors": sorted(behaviors), "keywords": [],
        "minimumSizeCentimeters": None, "maximumSizeCentimeters": round(float(length), 2) if length else None,
        "minimumDepthMeters": round(float(shallow), 2) if depth_ok else None, "maximumDepthMeters": round(float(deep), 2) if depth_ok else None,
        "summary": summary, "distinguishingFeatures": features,
        "typicalHabitat": " ".join([s for s in comment_sentences if HABITAT_WORDS.search(s)][:2]),
        "geographicRange": range_text, "cautions": [HAZARDS[h] for h in [(sp.get("Dangerous") or "").strip()] if h in HAZARDS],
        "imageAssetName": None, "regionalOccurrence": "unknown",
        "regionalOccurrenceNotes": "No global abundance in the source; location only boosts ranking.",
        "subregions": src.get("fao_names", []), "appearanceVariants": [], "similarSpecies": [], "bundledImage": None,
        "dataSources": [{
            "stableSourceID": f"{name}:SpecCode:{code}", "sourceName": f"{name} ({src['release']})",
            "sourceURL": url.format(code), "citationReference": main_ref, "reviewedFields": [],
            "accessedDate": ACCESSED, "sourceLicense": LICENSE}],
        "review": {"status": "draft", "reviewerNotes": f"Generated from {name} {src['release']} by Tools/FishBaseIntake/build.py; awaiting batch review.",
                   "reviewDate": None, "verifiedBy": None},
        "taxonomy": {"wormsAphiaID": None, "scientificNameAuthority": sp.get("Author"), "taxonomicClass": fam.get("Class"),
                     "order": fam.get("Order"), "family": fam.get("Family"), "genus": accepted.split(" ")[0],
                     "acceptedScientificName": accepted, "sourceScientificName": entry["inputName"]},
        "measurements": ({"typicalObservedMinimumCentimeters": None, "typicalObservedMaximumCentimeters": None,
                          "maximumRecordedCentimeters": round(float(length), 2), "type": ltype} if length and ltype else None),
        "tailShape": tail if tail and not tail.startswith("other") else None,
        "mouthAndHeadShape": mouth, "finAndSpineClues": fins,
    }


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


def load_sources(manifest, cache, offline, wanted):
    """Index the pinned tables by (server, SpecCode) for the wanted species only."""
    read = lambda sv, t, cols: fetch.read_table(manifest, cache, sv, t, cols, offline)
    out = {}
    for sv in sorted(manifest["servers"]):
        codes = {code for server, code in wanted if server == sv}
        release = manifest["servers"][sv]["release"]
        families = {r["FamCode"]: r for r in read(sv, "families", ["FamCode", "Family", "Order", "Class"])}
        refs = {r["RefNo"]: r for r in read(sv, "refrens", ["RefNo", "Author", "Year", "Title", "ShortCitation"])}
        countries = {r["C_Code"]: r["PAESE"] for r in read(sv, "countref", ["C_Code", "PAESE"])}
        fao_names = {r["AreaCode"]: r["FAO"] for r in read(sv, "faoarref", ["AreaCode", "FAO"])}
        def per_species(rows, key="SpecCode"):
            grouped = {}
            for r in rows:
                if r.get(key) in codes:
                    grouped.setdefault(r[key], []).append(r)
            return grouped
        species = per_species(read(sv, "species", ["SpecCode", "FBname", "Author", "FamCode", "Length", "LTypeMaxM", "DepthRangeShallow",
                                                   "DepthRangeDeep", "DemersPelag", "BodyShapeI", "Dangerous", "Comments", "SpeciesRefNo", "Saltwater", "Brack"]))
        names = per_species(read(sv, "comnames", ["SpecCode", "ComName", "Language", "PreferredName"]))
        ecology = per_species(read(sv, "ecology", ["SpecCode", *ECOLOGY_HABITATS, "Schooling", "Solitary", "Burrows", "FeedingType", "AssociationsWith"]))
        morph = per_species(read(sv, "morphdat", ["Speccode", "AddChars", "SexColors", "BodyShapeII", "CShape", "TypeofMouth", "PosofMouth",
                                                  "DorsalSpinesMin", "DorsalSpinesMax", "DorsalSoftRaysMin", "DorsalSoftRaysMax",
                                                  "AnalFinSpinesMin", "AnalFinSpinesMax", "Araymin", "Araymax", "BarbelsNo"]), key="Speccode")
        stocks = per_species(read(sv, "stocks", ["SpecCode", "StockDefs", "Level"]))
        fao = per_species(read(sv, "faoareas", ["SpecCode", "AreaCode", "Status"]))
        country = per_species(read(sv, "country", ["SpecCode", "C_Code", "Status"]))
        ok = lambda r: str(r.get("Status") or "").strip().lower() not in EXCLUDED_STATUSES
        for code in codes:
            sp = (species.get(code) or [{}])[0]
            english = sorted({r["ComName"].strip() for r in names.get(code, []) if r.get("Language") == "English" and r.get("ComName")},
                             key=lambda n: (n.lower() != (sp.get("FBname") or "").lower(), n.lower(), n))
            stock_rows = sorted(stocks.get(code, []), key=lambda r: (r.get("Level") != "species in general",))
            fao_codes = sorted({r["AreaCode"] for r in fao.get(code, []) if ok(r) and r["AreaCode"] in MARINE_FAO_AREAS})
            ref = refs.get(sp.get("SpeciesRefNo")) or {}
            out[(sv, code)] = {
                "release": release, "species": sp, "family": families.get(sp.get("FamCode")),
                "english_names": english, "ecology": ecology.get(code, []),
                "morphdat": (morph.get(code) or [None])[0],
                "range_text": next((r["StockDefs"] for r in stock_rows if r.get("StockDefs")), ""),
                "fao_codes": fao_codes, "fao_names": [fao_names[c] for c in fao_codes if c in fao_names],
                "countries": sorted({countries.get(r["C_Code"], "") for r in country.get(code, []) if ok(r)} - {""}),
                "main_ref": (ref.get("ShortCitation") or " ".join(filter(None, [str(ref.get("Author") or ""), str(ref.get("Year") or "")])).strip()
                             or (f"FishBase/SeaLifeBase reference {sp['SpeciesRefNo']}" if sp.get("SpeciesRefNo") else None)),
            }
    return out


def lives_in_sea(species_row):
    """Marine or brackish per the source; freshwater-only species are out of scope."""
    return truthy(species_row.get("Saltwater")) or truthy(species_row.get("Brack"))


def select_entries(resolution_rows, candidate_rows, existing_categories, crosswalk_ids=None):
    """Records to build: resolved, non-duplicate Tropical Pacific records and candidates.
    A candidate keeps its intake-crosswalk UUID, which reuses an existing workbook
    identity where there is one; uuid5 of the candidate ID is the crosswalk's own rule
    for new identities."""
    crosswalk_ids = crosswalk_ids or {}
    categories = {r["candidateID"]: r["proposedAppCategory"] for r in candidate_rows}
    entries = []
    for row in resolution_rows:
        if row["resolution"] not in ("exact", "synonym", "corrected") or row["duplicateOf"]:
            continue
        if row["inputKind"] == "existing" and row["pack"] != "TropicalPacific":
            continue
        if row["inputKind"] == "existing":
            entry_id, cats = row["inputID"], existing_categories.get(row["inputID"], [])
        else:
            entry_id = crosswalk_ids.get(row["inputID"]) or str(uuid.uuid5(CANDIDATE_NAMESPACE, row["inputID"]))
            cats = None
        entries.append(dict(row, id=entry_id, candidateCategory=categories.get(row["inputID"]), categories=cats))
    return entries


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", default=fetch.DEFAULT_CACHE)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--output", default=REPO / "Data/GlobalMarine/FishBase")
    args = parser.parse_args(argv)
    output = Path(args.output)
    resolution = list(csv.DictReader(open(output / "NameResolution.csv", newline="")))
    candidates = list(csv.DictReader(open(REPO / "Data/GlobalMarine/Expansion4000_CandidateQueue.csv", newline="")))
    packs = REPO / "DiveID/Resources/IdentificationPacks"
    existing = {name: json.loads((packs / name / "Creatures.json").read_text()) for name in ("Caribbean", "TropicalPacific")}
    existing_categories = {r["id"]: r.get("categories", []) for r in existing["TropicalPacific"]}
    with open(REPO / "Data/GlobalMarine/IntakeCrosswalk.csv", newline="") as f:
        crosswalk_ids = {r["candidateID"]: r["speciesID"] for r in csv.DictReader(f) if r["queue"] == "primary"}
    entries = select_entries(resolution, candidates, existing_categories, crosswalk_ids)
    sources = load_sources(fetch.load_manifest(), args.cache, args.offline, {(e["server"], int(e["specCode"])) for e in entries})
    profiles, freshwater_only = [], []
    for e in entries:
        src = sources[(e["server"], int(e["specCode"]))]
        if not lives_in_sea(src["species"]):
            freshwater_only.append(e["acceptedName"])
            continue
        family = src.get("family") or {}
        if not e["categories"]:
            e["categories"] = category_for(e["candidateCategory"], family.get("Family"), family.get("Class"))
        profiles.append(build_profile(e, src))
    reserved = {" ".join(n.lower().split()) for r in existing["Caribbean"] for n in (r["commonName"], r["scientificName"])}
    renamed = enforce_unique_names(profiles, reserved)
    drafts = output / "Drafts"
    drafts.mkdir(parents=True, exist_ok=True)
    for old in drafts.glob("batch-*.json"):
        old.unlink()
    for i in range(0, len(profiles), BATCH_SIZE):
        batch = profiles[i:i + BATCH_SIZE]
        text = "[\n" + ",\n".join(json.dumps(p, ensure_ascii=False) for p in batch) + "\n]\n"
        (drafts / f"batch-{i // BATCH_SIZE + 1:02d}.json").write_text(text)
    missing = lambda f: sum(1 for p in profiles if not p[f])
    report = {
        "records": len(profiles), "batches": (len(profiles) + BATCH_SIZE - 1) // BATCH_SIZE,
        "fromTropicalPacific": sum(p["dataSources"] and p["id"] in existing_categories for p in profiles),
        "fromCandidates": sum(p["id"] not in existing_categories for p in profiles),
        "commonNamesDisambiguated": len(renamed),
        "excludedFreshwaterOnly": sorted(freshwater_only),
        "missing": {f: missing(f) for f in ("categories", "colors", "markings", "bodyShapes", "habitats", "regions",
                                            "maximumSizeCentimeters", "maximumDepthMeters", "typicalHabitat", "measurements")},
        "summaryFromFallback": sum(1 for p in profiles if p["summary"].endswith(" species.") or "species; " in p["summary"]),
        "categories": dict(sorted({c: sum(c in p["categories"] for p in profiles) for p in profiles for c in p["categories"]}.items())),
    }
    (output / "BuildReport.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
