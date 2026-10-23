#!/usr/bin/env python3
"""Rebuild the starter catalogue from preserved input and the validated overlay.

The baseline is the pre-overlay pack from main d031795d. It is source input,
not publication approval. Edit review decisions, not generated Creatures.json.
"""
import json
from pathlib import Path
from catalog_review import apply_decisions, update_manifest, replace_catalogue_pair
from catalogue_validation import validate_catalogue

ROOT = Path(__file__).resolve().parents[2]


def generate():
    records = json.loads((ROOT / 'Data/CatalogReview/CaribbeanSourceBaseline.json').read_text())
    decisions = json.loads((ROOT / 'Data/CatalogReview/CaribbeanReviewDecisions.json').read_text())
    pack = ROOT / 'DiveID/Resources/IdentificationPacks/Caribbean'
    manifest = json.loads((pack / 'PackManifest.json').read_text())
    outcomes = apply_decisions(records, decisions, manifest['id'])
    if any(outcome['state'] != 'applied' for outcome in outcomes):
        raise ValueError(f'Stale or blocked overlay; catalogue not written: {outcomes}')
    update_manifest(manifest, records)
    validate_catalogue(records, manifest)
    return records, manifest, outcomes


def main():
    records, manifest, outcomes = generate()
    pack = ROOT / 'DiveID/Resources/IdentificationPacks/Caribbean'
    replace_catalogue_pair(pack / 'Creatures.json', pack / 'PackManifest.json', records, manifest)
    print(json.dumps(outcomes, indent=2))


if __name__ == '__main__':
    main()
