"""Resolve the 4,000 candidates and the existing app records to FishBase/SeaLifeBase species.

Each input name is matched in this order, against the pinned release:

1. exact: a valid species name (Genus + species) in exactly one database;
2. synonym: a species-level synonym whose status is synonym / accepted /
   provisionally accepted, pointing to exactly one species;
3. corrected: a misspelling fixed to the one species within a small edit
   distance (genus up to 2 edits with the same epithet, or epithet 1 edit
   within the same genus) of a valid name or of a synonym that resolves under
   rule 2. The original spelling is kept in the output.

A synonym marked "ambiguous synonym", or one pointing to several species, is
"ambiguous" and flagged for the owner's full review. "Misapplied name" rows
never resolve a name. Anything else is "unresolved".

Resolved inputs are de-duplicated by (database, SpecCode). An existing app
record keeps its identity; otherwise the first candidate in queue order does.
"""
import argparse
import csv
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE))
import fetch  # noqa: E402

RESOLVING_SYNONYM_STATUSES = {"synonym", "accepted name", "provisionally accepted name"}
AMBIGUOUS_SYNONYM_STATUS = "ambiguous synonym"
SPECIES_LEVELS = {"species", "nominotypical"}
MAX_GENUS_EDITS = 2
MAX_EPITHET_EDITS = 1
FIELDS = ["inputKind", "inputID", "pack", "inputName", "resolution", "flagged", "server", "specCode",
          "acceptedName", "correctedFrom", "duplicateOf", "note"]


def normalize(name):
    return " ".join(str(name).split()).lower()


def edit_distance(a, b, limit):
    """Levenshtein distance, or limit + 1 once it exceeds limit."""
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        if min(current) > limit:
            return limit + 1
        previous = current
    return previous[-1]


class NameIndex:
    def __init__(self, species_rows, synonym_rows):
        """species_rows: dicts with server, SpecCode, Genus, Species.
        synonym_rows: dicts with server, SpecCode, SynGenus, SynSpecies, Status, TaxonLevel."""
        self.valid, self.accepted = {}, {}
        self.by_genus, self.by_epithet = {}, {}
        for row in species_rows:
            if not row.get("Genus") or not row.get("Species"):
                continue
            key, code = normalize(f"{row['Genus']} {row['Species']}"), (row["server"], row["SpecCode"])
            self.valid.setdefault(key, set()).add(code)
            self.accepted[code] = f"{row['Genus']} {row['Species']}"
        self.synonyms = {}
        for row in synonym_rows:
            if not row.get("SynGenus") or not row.get("SynSpecies"):
                continue
            if normalize(row.get("TaxonLevel") or "") not in SPECIES_LEVELS:
                continue
            key = normalize(f"{row['SynGenus']} {row['SynSpecies']}")
            self.synonyms.setdefault(key, []).append(((row["server"], row["SpecCode"]), normalize(row.get("Status") or "")))
        # Spelling corrections may land on any name that resolves to one species.
        self.correctable = {key: codes for key, codes in self.valid.items() if len(codes) == 1}
        for key in self.synonyms:
            if key not in self.valid:
                resolution, codes = self._synonym(key)
                if resolution == "synonym":
                    self.correctable[key] = codes
        for key in self.correctable:
            genus, epithet = key.split(" ", 1)
            self.by_genus.setdefault(genus, set()).add(key)
            self.by_epithet.setdefault(epithet, set()).add(key)

    def _synonym(self, key):
        entries = [(code, status) for code, status in self.synonyms.get(key, []) if status != "misapplied name"]
        if not entries:
            return None, set()
        codes = {code for code, _ in entries}
        if len(codes) > 1:
            return "ambiguous", codes
        if any(status == AMBIGUOUS_SYNONYM_STATUS for _, status in entries):
            return "ambiguous", codes
        if all(status in RESOLVING_SYNONYM_STATUSES for _, status in entries):
            return "synonym", codes
        return None, set()

    def resolve(self, name):
        """Return (resolution, codes, correctedName, note)."""
        key = normalize(name)
        codes = self.valid.get(key, set())
        if len(codes) == 1:
            return "exact", codes, None, ""
        if len(codes) > 1:
            return "ambiguous", codes, None, "valid name in more than one database"
        resolution, codes = self._synonym(key)
        if resolution == "ambiguous":
            several = len(codes) > 1
            return "ambiguous", codes, None, "synonym of more than one species" if several else "marked ambiguous synonym"
        if resolution == "synonym":
            return "synonym", codes, None, ""
        return self._correct(key)

    def _correct(self, key):
        parts = key.split(" ")
        if len(parts) != 2:
            return "unresolved", set(), None, "not a binomial"
        genus, epithet = parts
        options = []
        for candidate in self.by_epithet.get(epithet, ()):
            d = edit_distance(genus, candidate.split(" ", 1)[0], MAX_GENUS_EDITS)
            if d <= MAX_GENUS_EDITS:
                options.append((d, candidate))
        for candidate in self.by_genus.get(genus, ()):
            d = edit_distance(epithet, candidate.split(" ", 1)[1], MAX_EPITHET_EDITS)
            if d <= MAX_EPITHET_EDITS:
                options.append((d, candidate))
        if not options:
            return "unresolved", set(), None, "no exact, synonym or close spelling match"
        best = min(d for d, _ in options)
        names = sorted({candidate for d, candidate in options if d == best})
        codes = set().union(*(self.correctable[n] for n in names))
        if len(names) > 1 or len(codes) > 1:
            return "unresolved", set(), None, "several equally close spellings: " + "; ".join(names)
        return "corrected", codes, names[0], f"{best} edit(s)"


# The regional packs whose records feed the global merge. Global itself is this
# pipeline's output, so reading it back as input would be circular.
SOURCE_PACKS = ("Caribbean", "TropicalPacific")


def load_inputs(repo=REPO):
    inputs = []
    for pack_dir in [repo / "DiveID/Resources/IdentificationPacks" / name for name in SOURCE_PACKS]:
        path = pack_dir / "Creatures.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        records = data if isinstance(data, list) else next(v for v in data.values() if isinstance(v, list))
        inputs += [{"inputKind": "existing", "inputID": r["id"], "pack": pack_dir.name, "inputName": r["scientificName"]} for r in records]
    with open(repo / "Data/GlobalMarine/Expansion4000_CandidateQueue.csv", newline="") as f:
        inputs += [{"inputKind": "candidate", "inputID": r["candidateID"], "pack": "", "inputName": r["scientificNameInput"]} for r in csv.DictReader(f)]
    return inputs


def resolve_all(index, inputs):
    rows, owner = [], {}
    for item in inputs:
        resolution, codes, corrected, note = index.resolve(item["inputName"])
        row = dict(item, resolution=resolution, flagged="yes" if resolution == "ambiguous" else "no",
                   server="", specCode="", acceptedName="", correctedFrom="", duplicateOf="", note=note)
        if resolution in ("exact", "synonym", "corrected"):
            (server, code), = codes
            row.update(server=server, specCode=str(code), acceptedName=index.accepted[(server, code)])
            if resolution == "corrected":
                row["correctedFrom"] = item["inputName"]
            # Existing records come first in `inputs`, so they keep their identity.
            if (server, code) in owner:
                row["duplicateOf"] = owner[(server, code)]
            else:
                owner[(server, code)] = item["inputID"]
        rows.append(row)
    return rows


def summarize(rows, manifest):
    counts = {}
    for row in rows:
        key = f"{row['inputKind']}.{row['resolution']}"
        counts[key] = counts.get(key, 0) + 1
    unique = {(r["server"], r["specCode"]) for r in rows if r["specCode"] and not r["duplicateOf"]}
    return {
        "release": {sv: manifest["servers"][sv]["release"] for sv in sorted(manifest["servers"])},
        "license": manifest["license"],
        "inputs": len(rows),
        "counts": dict(sorted(counts.items())),
        "flagged": sum(r["flagged"] == "yes" for r in rows),
        "duplicates": sum(bool(r["duplicateOf"]) for r in rows),
        "uniqueResolvedSpecies": len(unique),
    }


def build_index(manifest, cache, offline):
    species, synonyms = [], []
    for server in sorted(manifest["servers"]):
        species += [dict(r, server=server) for r in fetch.read_table(manifest, cache, server, "species", ["SpecCode", "Genus", "Species"], offline)]
        synonyms += [dict(r, server=server) for r in fetch.read_table(manifest, cache, server, "synonyms", ["SpecCode", "SynGenus", "SynSpecies", "Status", "TaxonLevel"], offline)]
    return NameIndex(species, synonyms)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--cache", default=fetch.DEFAULT_CACHE)
    parser.add_argument("--offline", action="store_true")
    parser.add_argument("--output", default=REPO / "Data/GlobalMarine/FishBase")
    args = parser.parse_args(argv)
    manifest = fetch.load_manifest()
    rows = resolve_all(build_index(manifest, args.cache, args.offline), load_inputs())
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    with open(output / "NameResolution.csv", "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    summary = summarize(rows, manifest)
    (output / "NameResolutionSummary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
