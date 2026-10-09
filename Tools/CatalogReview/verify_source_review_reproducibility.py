#!/usr/bin/env python3
"""Rebuild both catalogues and packets twice; reject any byte-level drift."""
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    paths = [
        *ROOT.glob('DiveID/Resources/IdentificationPacks/Caribbean/*.json'),
        *ROOT.glob('DiveID/Resources/IdentificationPacks/TropicalPacific/*.json'),
        *(ROOT / 'Reports' / name for name in (
            'TropicalPacificImportReport.json', 'TropicalPacificOutcomes.csv',
            'TropicalPacificReviewQueue.csv', 'FirstCatalogueReviewBatch.json',
            'CatalogueSourceReviewPass.json')),
    ]
    def hashes():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
    initial = hashes()
    for _ in range(2):
        for script in ('Tools/CatalogReview/regenerate_caribbean.py',
                       'Tools/CatalogImport/import_tropical_pacific.py',
                       'Tools/CatalogReview/prepare_source_review_pass.py',
                       'Tools/CatalogReview/prepare_review_batch.py'):
            subprocess.run([sys.executable, str(ROOT / script)], cwd=ROOT,
                           check=True, stdout=subprocess.DEVNULL)
        if hashes() != initial:
            raise SystemExit('Generated artifacts drifted; inspect changes and rerun after committing intended outputs.')
    output = {'identicalRegenerationPasses': 2, 'sha256': initial}
    (ROOT / 'Reports/SourceReviewReproducibility.json').write_text(json.dumps(output, indent=2) + '\n')
    print('Two byte-identical regenerations; nine catalogue/manifest/report artifacts checked.')


if __name__ == '__main__':
    main()
