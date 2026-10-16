#!/usr/bin/env python3
"""Resumable global staging. Never writes to application resources."""
import argparse
import csv
import json
from collections import Counter, defaultdict
from pathlib import Path
from intake import ROOT, DATA, atomic_json, digest, intake, normalize, write_csv
from worms import Cache, resolve, payload_hash

CROSS_FIELDS = ['candidateID','queue','sourceName','speciesID','identityStatus','taxonomyStatus','acceptedAphiaID','acceptedScientificName','disposition','canonicalSpeciesID','diagnostics','reviewStatus']
CANONICAL_FIELDS = ['speciesID','acceptedScientificName','acceptedAphiaID','sourceCandidateIDs','genus','family','order','class','authority','rank','isMarine','reviewStatus']


def checkpoint_path(directory, queue, batch):
    return directory / f'{queue}-{batch:02d}.json'


def load_results(directory, input_fingerprint):
    results = {}
    for path in sorted(directory.glob('*.json')):
        document = json.loads(path.read_text())
        if document.get('inputFingerprint') != input_fingerprint:
            raise ValueError(f'Stale checkpoint: {path}; use a separate checkpoint directory')
        for row in document['results']:
            cid = row['candidateID']
            if cid in results:
                raise ValueError(f'Duplicate checkpoint identity: {cid}')
            results[cid] = row
    return results


def canonicalize(candidates, reserves, links, results, existing_by_name, baseline_results):
    """Resolve collisions deterministically; reserves fill confirmed collisions only."""
    crosswalk, canonical, duplicate_rows = [], {}, []
    existing_by_aphia = defaultdict(set)
    baseline_complete = True
    for name, ids in sorted(existing_by_name.items()):
        resolved = baseline_results.get(name, {})
        if resolved.get('status') != 'confirmed':
            baseline_complete = False
        else:
            existing_by_aphia[resolved['acceptedAphiaID']].update(ids)
    replacements_needed = 0
    primary_ids = {r['candidateID'] for r in candidates}
    for link in links:
        cid = link['candidateID']; result = results.get(cid, {})
        aid = result.get('acceptedAphiaID') if result.get('status') == 'confirmed' else None
        row = {**{key:link[key] for key in ('candidateID','queue','sourceName','speciesID','identityStatus')},
               'taxonomyStatus':result.get('status','not_attempted'), 'acceptedAphiaID':aid,
               'acceptedScientificName':result.get('acceptedScientificName'), 'disposition':'pending_taxonomy',
               'canonicalSpeciesID':None, 'diagnostics':';'.join(result.get('diagnostics',['not_attempted'])), 'reviewStatus':'draft'}
        if link['speciesID'] is None or link['sourceLineage'] == 'source_name_not_found':
            row['disposition'] = 'intake_conflict'
        elif aid is not None:
            accepted_name = normalize(result['acceptedScientificName'])
            existing = existing_by_aphia.get(aid,set()) | existing_by_name.get(accepted_name,set()) | existing_by_name.get(normalize(link['sourceName']),set())
            if len(existing) > 1:
                row['disposition'] = 'conflicting_existing_UUIDs'
            elif existing and link['speciesID'] not in existing:
                # Same accepted taxon, reuse the known UUID. Never replace an approved record.
                row.update(disposition='duplicate_existing_taxon', canonicalSpeciesID=next(iter(existing)))
            elif link['existingAppRecord']:
                row.update(disposition='duplicate_existing_taxon', canonicalSpeciesID=link['speciesID'])
            elif aid in canonical:
                row.update(disposition='duplicate_accepted_taxon', canonicalSpeciesID=canonical[aid]['speciesID'])
                canonical[aid]['sourceCandidateIDs'].append(cid)
            elif cid not in primary_ids and replacements_needed == 0:
                row['disposition'] = 'reserve_not_needed'
            else:
                sid = next(iter(existing)) if existing else link['speciesID']
                row.update(disposition='canonical_draft', canonicalSpeciesID=sid)
                canonical[aid] = {'speciesID':sid, 'acceptedScientificName':result['acceptedScientificName'],
                                  'acceptedAphiaID':aid, 'sourceCandidateIDs':[cid],
                                  **{key:result.get(key) for key in ('genus','family','order','class','authority','rank','isMarine')}, 'reviewStatus':'draft'}
                if cid not in primary_ids:
                    replacements_needed -= 1
            if row['disposition'].startswith('duplicate_'):
                duplicate_rows.append({key:row[key] for key in ('candidateID','sourceName','acceptedAphiaID','canonicalSpeciesID','disposition')})
                if cid in primary_ids:
                    replacements_needed += 1
        crosswalk.append(row)
    # An accepted taxon can still collide with an unresolved baseline synonym.
    # Keep all exports blocked until the baseline taxonomy comparison is complete.
    return crosswalk, list(canonical.values()), duplicate_rows, baseline_complete


def generate(root, candidates, reserves, links, intake_report, existing, checkpoint_dir, baseline_dir, output, report_dir):
    fingerprint = payload_hash(intake_report['inputSHA256'])
    results = load_results(checkpoint_dir, fingerprint)
    baseline = load_results(baseline_dir, fingerprint)
    crosswalk, canonical, duplicates, baseline_complete = canonicalize(candidates,reserves,links,results,existing,baseline)
    baseline_complete = baseline_complete and not intake_report['unreadableExistingIdentityIDs']
    write_csv(output/'OriginalNameCrosswalk.csv',crosswalk,CROSS_FIELDS)
    canonical_csv = [{**r,'sourceCandidateIDs':';'.join(r['sourceCandidateIDs'])} for r in sorted(canonical,key=lambda r:r['acceptedAphiaID'])]
    write_csv(output/'CanonicalTaxa.csv',canonical_csv,CANONICAL_FIELDS)
    write_csv(report_dir/'GlobalMarine4000Duplicates.csv',duplicates,['candidateID','sourceName','acceptedAphiaID','canonicalSpeciesID','disposition'])
    unresolved = [r for r in crosswalk if r['disposition'] not in ('canonical_draft','duplicate_existing_taxon','duplicate_accepted_taxon','reserve_not_needed')]
    write_csv(report_dir/'GlobalMarine4000Unresolved.csv',unresolved,CROSS_FIELDS)
    primary = crosswalk[:len(candidates)]
    report = {'schemaVersion':1,'inputFingerprint':fingerprint,'primaryCandidates':len(candidates),'reserveCandidates':len(reserves),
              'primaryTaxonomicallyConfirmed':sum(r['taxonomyStatus']=='confirmed' for r in primary),
              'uniqueCanonicalTaxa':len(canonical),'primaryUnresolved':sum(r['taxonomyStatus']!='confirmed' for r in primary),
              'primaryDispositionCounts':dict(Counter(r['disposition'] for r in primary)),
              'primaryDiagnostics':dict(Counter(r['diagnostics'] for r in primary)),
              'baselineNames':len(existing),'baselineTaxonomyComplete':baseline_complete,
              'humanVerifiedNewProfiles':0,'publicationEligibleNewProfiles':0,
              'checkpointInputFingerprint':fingerprint}
    atomic_json(report_dir/'GlobalMarine4000Resolution.json',report)
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--batch',type=int,required=True,help='1-based checkpoint of at most 250 rows')
    parser.add_argument('--queue',choices=['primary','reserve','baseline'],default='primary')
    parser.add_argument('--resume',action='store_true',help='Reuse cached successes and retry pending results')
    parser.add_argument('--offline-cache-only',action='store_true')
    parser.add_argument('--dry-run',action='store_true',help='Validate/replay only; no network or file writes')
    parser.add_argument('--cache',type=Path,default=DATA/'WoRMSCache')
    parser.add_argument('--checkpoints',type=Path,default=DATA/'Checkpoints')
    parser.add_argument('--baseline-checkpoints',type=Path,default=DATA/'BaselineCheckpoints')
    parser.add_argument('--output',type=Path,default=DATA)
    parser.add_argument('--report',type=Path,default=ROOT/'Reports',help='Report directory')
    args=parser.parse_args()
    # Output isolation is mandatory even with custom flags.
    for path in (args.cache,args.checkpoints,args.baseline_checkpoints,args.output,args.report):
        if (ROOT/'DiveID').resolve() in path.resolve().parents or path.resolve() == (ROOT/'DiveID').resolve():
            parser.error('Global staging cannot write into application resources')
    candidates,reserves,links,audit,existing=intake()
    fingerprint=payload_hash(audit['inputSHA256'])
    queue = candidates if args.queue=='primary' else reserves if args.queue=='reserve' else [{'candidateID':name,'scientificNameInput':name} for name in sorted(existing)]
    if args.batch < 1 or (args.batch-1)*250 >= len(queue):
        parser.error('Batch is outside this queue')
    if args.queue=='reserve':
        current=load_results(args.checkpoints,fingerprint)
        cross,_,duplicates,_=canonicalize(candidates,reserves,links,current,existing,load_results(args.baseline_checkpoints,fingerprint))
        if not duplicates:
            parser.error('Reserve processing requires a confirmed accepted-taxon collision')
    directory=args.baseline_checkpoints if args.queue=='baseline' else args.checkpoints
    path=checkpoint_path(directory,args.queue,args.batch)
    if path.exists() and not args.resume and not args.dry_run:
        parser.error('Checkpoint exists; use --resume')
    previous=load_results(directory,fingerprint)
    batch=queue[(args.batch-1)*250:args.batch*250]
    records=[]
    preserved = {r['candidateID']:previous[r['candidateID']] for r in batch if r['candidateID'] in previous}
    for row in batch:
        # Always replay cached responses: a repaired/updated cache invalidates stale decisions.
        cache=Cache(args.cache,offline=args.offline_cache_only,dry_run=args.dry_run)
        result=resolve(row['scientificNameInput'],cache)
        result['candidateID']=row['candidateID']
        records.append(result)
        preserved[row['candidateID']] = result
        if not args.dry_run:
            atomic_json(path,{'schemaVersion':1,'inputFingerprint':fingerprint,'batch':args.batch,'queue':args.queue,'results':[preserved[r['candidateID']] for r in batch if r['candidateID'] in preserved]})
    if args.dry_run:
        print(json.dumps({'dryRun':True,'rows':len(records),'states':dict(Counter(r['status'] for r in records))},sort_keys=True));return
    atomic_json(args.report/'GlobalMarine4000Intake.json',audit)
    report=generate(ROOT,candidates,reserves,links,audit,existing,args.checkpoints,args.baseline_checkpoints,args.output,args.report)
    print(json.dumps(report,sort_keys=True))

if __name__=='__main__':
    main()
