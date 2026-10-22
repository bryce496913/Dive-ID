"""The published Global pack keeps the identification evidence the source supports
(DiveIDTests/Fixtures/GlobalEvidence.v1.json; the Swift GlobalEvidenceTests read the same fixture)."""
import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
FIXTURE = json.loads((REPO / "DiveIDTests/Fixtures/GlobalEvidence.v1.json").read_text())
PACK = {r["id"]: r for r in json.loads((REPO / "DiveID/Resources/IdentificationPacks/Global/Creatures.json").read_text())}


def values(record, expectation):
    if "variant" in expectation:
        variants = [v for v in record.get("appearanceVariants") or [] if v["lifeStage"] == expectation["variant"]]
        found = [x for v in variants for x in (v.get(expectation["field"]) or [])]
        return found if variants else None
    value = record.get(expectation["field"])
    return value if isinstance(value, list) else [value] if value else []


class GlobalEvidenceTests(unittest.TestCase):
    def test_source_supported_evidence_is_present(self):
        failures = []
        for species in FIXTURE["species"]:
            record = PACK.get(species["speciesID"])
            if record is None:
                failures.append(f"{species['name']}: missing from Global")
                continue
            for e in species["expect"]:
                found = values(record, e)
                label = f"{species['name']}: {e.get('variant', 'main')}.{e['field']}"
                if found is None:
                    failures.append(f"{label}: no {e['variant']} variant ({e['source']})")
                elif "includes" in e and not any(e["includes"] in str(v).lower() for v in found):
                    failures.append(f"{label} lacks '{e['includes']}' ({e['source']}); has {found}")
                elif "excludes" in e and any(e["excludes"] == str(v).lower() for v in found):
                    failures.append(f"{label} wrongly has '{e['excludes']}' ({e['source']})")
        self.assertEqual(failures, [], "\n" + "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
