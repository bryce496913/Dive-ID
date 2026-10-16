#!/usr/bin/env python3
"""Replay all sixteen checkpoints twice and prove byte stability and app isolation."""
import json
import subprocess
import sys
from pathlib import Path
from intake import ROOT, DATA, digest, atomic_json


def hashes(paths):return {str(p.relative_to(ROOT)):digest(p) for p in sorted(paths)}


def main():
    generated=[DATA/name for name in ('IntakeCrosswalk.csv','OriginalNameCrosswalk.csv','CanonicalTaxa.csv','EnrichmentStaging.json','DraftProfiles.json')]
    generated+=list((DATA/'Checkpoints').glob('*.json'))
    generated+=[ROOT/'Reports'/name for name in ('GlobalMarine4000Intake.json','GlobalMarine4000Resolution.json','GlobalMarine4000Duplicates.csv','GlobalMarine4000Unresolved.csv','GlobalMarine4000RegionEligibility.json')]
    def protected_paths():
        return [p for directory in ('DiveID','DiveIDTests/Fixtures','Data/Evaluation','Data/CatalogReview') for p in (ROOT/directory).rglob('*') if p.is_file()]
    protected=protected_paths()
    before=hashes(generated); app_before=hashes(protected)
    for _ in range(2):
        subprocess.run([sys.executable,str(ROOT/'Tools/GlobalMarineImport/intake.py')],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
        for batch in range(1,17):
            subprocess.run([sys.executable,str(ROOT/'Tools/GlobalMarineImport/process.py'),'--batch',str(batch),'--resume','--offline-cache-only'],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
        subprocess.run([sys.executable,str(ROOT/'Tools/GlobalMarineImport/enrichment.py')],cwd=ROOT,check=True,stdout=subprocess.DEVNULL)
        if hashes(generated)!=before:raise SystemExit('Generated global staging artifacts drifted')
        if hashes(protected_paths())!=app_before:raise SystemExit('Protected application/fixture/review content changed')
    atomic_json(ROOT/'Reports/GlobalMarine4000Reproducibility.json',{'schemaVersion':1,'identicalPasses':2,'generatedSHA256':before,'protectedSHA256':app_before})
    print(f'Two identical replays: {len(generated)} outputs; {len(protected)} protected files unchanged.')

if __name__=='__main__':main()
