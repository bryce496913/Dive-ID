"""Derive the dive regions offered beside Global from Global's own records.

Each region is a list of Global record IDs (`Members.json`) plus a manifest, written to
DiveID/Resources/IdentificationPacks/<Region>/. The app loads Global and keeps only the
listed records, so a regional search sees exactly the Global records, with their
review status, text and ranking data unchanged. Release filtering still applies: only
verified records are shown. Nothing here edits a species record.

Membership (owner decision, 2026-10-26). A species belongs to every region it occurs
in; one found in none of them (for example only in the temperate North Atlantic)
stays in Global alone.

- FAO areas come from each record's `subregions`, which `build.py` wrote from the
  counted FAO rows of the pinned FishBase/SeaLifeBase distribution.
- Countries come from the same staged distribution (Distribution.json and
  DistributionAdditions.json), counted rows only. They are needed only to split the
  Eastern Central Pacific (FAO 77), which holds both Hawaii/Polynesia and the
  Pacific coast of Mexico and Central America.
- Records with no staged distribution (the 8 field-guide Caribbean species) use
  their `subregions` and `regions` alone.

Regions:
- Tropical Atlantic: FAO 31, 34 or 41, or a Caribbean locality.
- Indo-Pacific: FAO 51, 57, 61, 71 or 81, or FAO 77/87 with a Pacific island
  (Hawaii, French Polynesia, Tonga, Samoa and others).
- Pacific Coast: FAO 67, 77 or 87 with an Americas Pacific coast. A country with
  only a Pacific coast counts directly. A country with two coasts (Canada, USA,
  Mexico, Central America, Colombia) counts in FAO 67 or 87, and in FAO 77 only for a
  species with no Atlantic FAO area and no Pacific island record, because FishBase
  files Hawaii under the USA.
- Mediterranean: FAO 37 (Mediterranean and Black Sea).

`--check` exits nonzero when the committed files differ from a fresh derivation.
Run this after `publish_global.py` changes Global.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
import distribution  # noqa: E402
import fetch  # noqa: E402

PACKS = REPO / "DiveID/Resources/IdentificationPacks"
GLOBAL = PACKS / "Global"

FAO_NAMES = {
    "Northwest Atlantic": 21, "Northeast Atlantic": 27, "Western Central Atlantic": 31,
    "Eastern Central Atlantic": 34, "Mediterranean and Black Sea": 37, "Southwest Atlantic": 41,
    "Southeast Atlantic": 47, "Western Indian Ocean": 51, "Eastern Indian Ocean": 57,
    "Northwest Pacific": 61, "Northeast Pacific": 67, "Western Central Pacific": 71,
    "Eastern Central Pacific": 77, "Southwest Pacific": 81, "Southeast Pacific": 87,
}
# Locality subregions and vocabulary regions carried by the field-guide Caribbean records.
CARIBBEAN_LOCALITIES = {"Bahamas", "Belize", "Bonaire", "Cayman Islands", "Florida Keys", "Puerto Rico"}
CARIBBEAN_REGIONS = {"caribbean", "western atlantic"}

ATLANTIC_AREAS = {21, 31, 41}
# FishBase country codes (countref.C_Code).
PACIFIC_ISLANDS = {
    "840B",  # Hawaii
    "258", "250A", "250C", "250D",  # French Polynesia, Society, Tuamotu, Marquesas
    "612", "396", "488", "296", "581", "872", "152A",  # Pitcairn, Johnston, Midway, Kiribati, US Minor Outlying, Wake, Easter I.
    "776", "184", "016", "570", "882", "772", "798", "876", "242",  # Tonga, Cook, American Samoa, Niue, Samoa, Tokelau, Tuvalu, Wallis and Futuna, Fiji
}
PACIFIC_ONLY_AMERICAS = {
    "840A", "I484", "I250", "222", "I188",  # Alaska, Revillagigedo, Clipperton, El Salvador, Cocos I.
    "218", "218A", "604", "152", "152B", "152D",  # Ecuador, Galapagos, Peru, Chile, Juan Fernandez, Desventuradas
}
TWO_COAST_AMERICAS = {"124", "840", "484", "320", "340", "558", "188", "591", "170"}  # Canada .. Colombia


def tropical_atlantic(areas, countries, record):
    return bool(areas & {31, 34, 41} or set(record.get("subregions", [])) & CARIBBEAN_LOCALITIES
                or set(record.get("regions", [])) & CARIBBEAN_REGIONS)


def indo_pacific(areas, countries, record):
    return bool(areas & {51, 57, 61, 71, 81} or (areas & {77, 87} and countries & PACIFIC_ISLANDS))


def pacific_coast(areas, countries, record):
    if not areas & {67, 77, 87}:
        return False
    if countries & PACIFIC_ONLY_AMERICAS:
        return True
    if not countries & TWO_COAST_AMERICAS:
        return False
    return bool(areas & {67, 87}) or not (areas & ATLANTIC_AREAS or countries & PACIFIC_ISLANDS)


def mediterranean(areas, countries, record):
    return 37 in areas


REGIONS = [
    {
        "id": "tropical-atlantic", "directory": "TropicalAtlantic", "member": tropical_atlantic,
        "displayName": "Tropical Atlantic Regions",
        "shortDescription": "Global species recorded from the tropical Atlantic",
        "geographicScope": "The Caribbean Sea, Gulf of Mexico, Florida, the Bahamas and Bermuda; "
                           "Brazil and the southwest Atlantic; and West Africa with the Canary and Cape Verde Islands.",
        "regionAliases": ["Atlantic", "Western Atlantic", "Caribbean", "Florida", "Bahamas", "Bermuda", "Gulf of Mexico",
                          "Belize", "Cayman Islands", "Cozumel", "Bonaire", "Curaçao", "Curacao", "Aruba", "Turks and Caicos",
                          "Puerto Rico", "US Virgin Islands", "British Virgin Islands", "Dominican Republic", "Jamaica"],
    },
    {
        "id": "indo-pacific", "directory": "IndoPacific", "member": indo_pacific,
        "displayName": "Indo-Pacific Regions",
        "shortDescription": "Global species recorded from the Indian and western and central Pacific Oceans",
        "geographicScope": "The Indian Ocean and western and central Pacific: the Red Sea, East Africa, Madagascar, "
                           "the Maldives, Thailand, Indonesia, the Philippines, Papua New Guinea, Australia, Japan, "
                           "Fiji, Hawaii and French Polynesia.",
        "regionAliases": ["Indo-Pacific", "Indian", "Pacific", "Tropical Pacific", "Australia", "Philippines",
                          "Indonesia", "Fiji", "Hawaii"],
    },
    {
        "id": "pacific-coast", "directory": "PacificCoast", "member": pacific_coast,
        "displayName": "Pacific Coast Regions",
        "shortDescription": "Global species recorded from the Pacific coasts of the Americas",
        "geographicScope": "The eastern Pacific coasts of the Americas: Alaska, Canada, the US West Coast, Pacific "
                           "Mexico and the Gulf of California, Central America, Colombia, Ecuador, the Galápagos, Peru and Chile.",
        "regionAliases": ["Pacific"],
    },
    {
        "id": "mediterranean", "directory": "Mediterranean", "member": mediterranean,
        "displayName": "Mediterranean",
        "shortDescription": "Global species recorded from the Mediterranean and Black Sea",
        "geographicScope": "The Mediterranean Sea and Black Sea: Spain, France, Italy, Malta, Croatia, Greece, "
                           "Türkiye, Cyprus, Israel, Egypt and Tunisia.",
        "regionAliases": [],
    },
]
RULES = {
    "tropical-atlantic": "FAO 31, 34 or 41, or a Caribbean locality",
    "indo-pacific": "FAO 51, 57, 61, 71 or 81, or FAO 77/87 with a Pacific island country",
    "pacific-coast": "FAO 67, 77 or 87 with an Americas Pacific coast country (two-coast countries: FAO 67/87, "
                     "or FAO 77 without an Atlantic FAO area or Pacific island record)",
    "mediterranean": "FAO 37",
}


def source_key(record):
    for prefix, key in (("FishBase:SpecCode:", "fb:"), ("SeaLifeBase:SpecCode:", "slb:")):
        for source in record.get("dataSources", []):
            stable = source.get("stableSourceID") or ""
            if stable.startswith(prefix):
                return key + stable[len(prefix):]
    return None


def load_distribution():
    staged = distribution.read_staged(distribution.DEFAULT_OUTPUT, distribution.source_of(fetch.load_manifest()))
    return staged["species"]


def is_reviewed(record):
    return (record.get("review") or {}).get("status") in ("sourceChecked", "verified")


def is_eligible(record):
    return (record.get("review") or {}).get("status") == "verified" and bool(record.get("categories"))


def derive(records, species_distribution, global_manifest, global_digest):
    """Returns {directory: (manifest, members)} for every region."""
    located = []
    for record in records:
        areas = {FAO_NAMES[name] for name in record.get("subregions", []) if name in FAO_NAMES}
        entry = species_distribution.get(source_key(record) or "")
        countries = {c["code"] for c in (entry or {}).get("countries", []) if c.get("counts")}
        located.append((record, areas, countries))
    outputs = {}
    for region in REGIONS:
        chosen = [record for record, areas, countries in located if region["member"](areas, countries, record)]
        manifest = {
            "id": region["id"], "schemaVersion": 1, "packVersion": 1,
            "displayName": region["displayName"], "shortDescription": region["shortDescription"],
            "geographicScope": region["geographicScope"], "regionAliases": region["regionAliases"],
            "speciesCount": len(chosen), "speciesResourceName": "Members", "imageSubdirectory": "Images",
            "includedWithApp": True, "lastDataReviewDate": None,
            "includedRecordCount": len(chosen),
            "humanReviewedRecordCount": sum(map(is_reviewed, chosen)),
            "publicationEligibleRecordCount": sum(map(is_eligible, chosen)),
        }
        members = {
            "sourcePackID": global_manifest["id"], "sourcePackVersion": global_manifest["packVersion"],
            "sourceSHA256": global_digest, "rule": RULES[region["id"]],
            "speciesIDs": sorted(record["id"] for record in chosen),
        }
        outputs[region["directory"]] = (manifest, members)
    return outputs


def render(value):
    return json.dumps(value, indent=2, ensure_ascii=False) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the committed region files are stale")
    args = parser.parse_args(argv)
    data = (GLOBAL / "Creatures.json").read_bytes()
    outputs = derive(json.loads(data), load_distribution(), json.loads((GLOBAL / "PackManifest.json").read_text()),
                     hashlib.sha256(data).hexdigest())
    stale = []
    for directory, (manifest, members) in outputs.items():
        for name, value in (("PackManifest.json", manifest), ("Members.json", members)):
            path = PACKS / directory / name
            text = render(value)
            if path.exists() and path.read_text() == text:
                continue
            stale.append(str(path.relative_to(REPO)))
            if not args.check:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
        print(f"{manifest['displayName']}: {manifest['includedRecordCount']} records, "
              f"{manifest['publicationEligibleRecordCount']} approved")
    if args.check and stale:
        print("Stale region files (run Tools/FishBaseIntake/derive_regions.py):\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
