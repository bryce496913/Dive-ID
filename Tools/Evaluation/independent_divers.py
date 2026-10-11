#!/usr/bin/env python3
"""Custodian-only import/freeze/run. Never print case text or per-case failures."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / 'Data/Evaluation/IndependentProtocol.v1.json'

def digest(data):
    return hashlib.sha256(data).hexdigest()

def require(value, message):
    if not value:
        raise ValueError(message)  # Deliberately no submitted values in errors.

def validate(document):
    require(document.get('schemaVersion') == 1, 'Unsupported input version')
    require(document.get('protocolVersion') == 'independent-v1', 'Protocol mismatch')
    require(isinstance(document.get('datasetVersion'), str) and document['datasetVersion'].strip(), 'Dataset version required')
    rows = document.get('observations')
    require(isinstance(rows, list), 'Observations must be an array')
    seen, texts, authors, encounters = set(), set(), {}, {}
    cases = []
    for row in rows:
        require(isinstance(row, dict), 'Invalid observation')
        key = str(uuid.UUID(row['observationID']))
        require(key not in seen, 'Duplicate observation ID'); seen.add(key)
        description = row['description']
        require(isinstance(description, str) and 1 <= len(description.strip()) <= 4000, 'Invalid description length')
        text_key = digest(' '.join(description.casefold().split()).encode())
        require(text_key not in texts, 'Duplicate description requires adjudication'); texts.add(text_key)
        collected = dt.date.fromisoformat(row['collectionDate'])
        require(row['region'] in ('caribbean', 'tropical-pacific'), 'Unsupported region')
        require(row['language'] == 'en', 'v1 evaluates English only; retain other languages outside this cohort')
        author = row['author']
        require(author['kind'] == 'human' and author['attestsOwnUnpromptedWords'] is True, 'Independent human authorship attestation required')
        require(row['consentForEvaluation'] is True, 'Evaluation consent required')
        require(isinstance(row['priorExposure'], bool) and isinstance(row['usedForDevelopment'], bool), 'Exposure flags required')
        for field in ('participantID',):
            require(isinstance(author[field], str) and author[field].strip(), 'Author ID required')
        for field in ('cohortID', 'encounterID'):
            require(isinstance(row[field], str) and row[field].strip(), 'Grouping metadata required')
        for mapping, value in ((authors, author['participantID']), (encounters, row['encounterID'])):
            require(value not in mapping or mapping[value] == row['cohortID'], 'Linked observations must share a cohort')
            mapping[value] = row['cohortID']
        label = row['label']
        kind = label['kind']
        require(kind in ('identification', 'ambiguous', 'noMatch', 'regionConflict', 'unresolved'), 'Invalid label kind')
        ids = label['acceptableSpeciesIDs']
        require(isinstance(ids, list) and len(ids) == len(set(ids)), 'Identity list must be unique')
        ids = [str(uuid.UUID(x)) for x in ids]
        require(bool(ids) if kind in ('identification', 'ambiguous') else not ids, 'Identity set inconsistent with label')
        if kind != 'unresolved':
            require(label['verifierID'].strip() and label['verifierID'] != author['participantID'], 'Independent verifier required')
            require(dt.date.fromisoformat(label['verificationDate']) >= collected, 'Verification predates collection')
            require(label['verifiedWithoutAppResults'] is True, 'App-independent verification required')
            require(label['notes'].strip() and isinstance(label['evidenceReferences'], list) and label['evidenceReferences'] and all(isinstance(x, str) and x.strip() for x in label['evidenceReferences']), 'Traceable identity evidence and rationale required')
        assignment = 'holdout' if int(digest(('independent-v1:' + row['cohortID']).encode())[:8], 16) % 5 == 0 else 'development'
        split = 'development' if row['priorExposure'] or row['usedForDevelopment'] else assignment
        cases.append({'id':str(uuid.uuid5(uuid.NAMESPACE_URL, 'dive-id:independent:'+key)),
                      'description':description, 'selectedPackID':row['region'], 'kind':kind,
                      'expectedSpeciesIDs':ids, 'acceptableSpeciesIDs':[],
                      'maximumAcceptableRank':3 if kind == 'identification' else 10 if kind == 'ambiguous' else None,
                      'maximumConfidence':0.64 if kind == 'ambiguous' else 1.0,
                      'provenance':'independently-authored-human' if not row['priorExposure'] else 'human-exposed-development',
                      'evidenceIDs':[], 'split':split, 'originalAssignment':assignment})
    exposed = {r['cohortID'] for r in rows if r['priorExposure'] or r['usedForDevelopment']}
    for row, case in zip(rows, cases):
        if row['cohortID'] in exposed:
            case['split'] = 'development'
    return cases

def lock_state():
    require(not subprocess.check_output(['git','status','--porcelain'],cwd=ROOT), 'Freeze requires a clean committed checkout')
    paths = [PROTOCOL, *sorted((ROOT/'DiveID/Resources/IdentificationPacks').rglob('*.json'))]
    return {'candidateSHA':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'trackedDiff':digest(subprocess.check_output(['git','diff','HEAD','--','DiveID','DiveIDTests','Package.swift','Tools/Evaluation','Data/Evaluation'],cwd=ROOT)),
            'files':{str(p.relative_to(ROOT)):digest(p.read_bytes()) for p in paths},
            'engine':'production-bm25-50-biological', 'displayLimit':10}

def private_directory(path):
    path = path.resolve()
    require(not path.is_relative_to(ROOT.resolve()), 'Custodian data must be outside the repository')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(path.stat().st_mode & 0o077 == 0, 'Custodian directory must have mode 0700')
    return path

def save_new(path, value):
    with path.open('x') as f:
        os.chmod(path, 0o600)
        json.dump(value, f, indent=2); f.write('\n')

def freeze(source, directory):
    require(source is not None, 'Source required')
    require(not source.resolve().is_relative_to(ROOT.resolve()), 'Source must remain outside repository')
    source_bytes = source.read_bytes(); doc = json.loads(source_bytes)
    cases = validate(doc)
    require(cases, 'No supplied descriptions: baseline unavailable')
    state = lock_state()
    directory = private_directory(directory)
    payload = {'schemaVersion':1,'suiteID':doc['datasetVersion'],'cases':cases,'evidence':[]}
    # Original provenance and labels retained privately, never in development output.
    save_new(directory/'provenance.json', doc)
    save_new(directory/'cases.json', payload)
    manifest = {'schemaVersion':1,'datasetVersion':doc['datasetVersion'], 'sourceSHA256':digest(source_bytes),
                'casesSHA256':digest((directory/'cases.json').read_bytes()),'provenanceSHA256':digest((directory/'provenance.json').read_bytes()),'state':state,
                'protocolSHA256':digest(PROTOCOL.read_bytes()),'frozenAt':dt.datetime.now(dt.timezone.utc).isoformat()}
    save_new(directory/'manifest.json', manifest)
    return {'imported':len(cases), 'baseline':'not run', 'publicCaseDetails':False}

def aggregate(rows):
    groups = []
    for access in ('experimentalDevelopment','publication'):
        for split in ('development','holdout'):
            selected = [r for r in rows if r['access']==access and r['split']==split]
            eligible = [r for r in selected if not r['blocked'] and r['kind']!='unresolved']
            positives = [r for r in eligible if r['kind']=='identification']
            def rate(num, den): return {'hits':num,'denominator':den,'rate':num/den if den else None}
            metrics = {'candidateRecall':rate(sum(r['recalled'] for r in positives),len(positives))}
            for k in (1,3,10): metrics['top'+str(k)] = rate(sum(r['rank'] is not None and r['rank']<=k for r in positives),len(positives))
            for kind,key in [('noMatch','noMatchCorrect'),('ambiguous','ambiguityCorrect'),('regionConflict','regionConflictCorrect')]:
                subset=[r for r in eligible if r['kind']==kind]
                metrics[key]=rate(sum(r['outcomeCorrect'] for r in subset),len(subset))
            metrics['confidenceCompliant']=rate(sum(r['confidenceOK'] for r in eligible),len(eligible))
            sufficient = len(positives)>=30 and all(metrics[k]['denominator']>=10 for k in ('noMatchCorrect','ambiguityCorrect','regionConflictCorrect'))
            criteria=json.loads(PROTOCOL.read_text())['minimumRates']
            passed=all(metrics[k]['rate'] is not None and metrics[k]['rate']>=v for k,v in criteria.items())
            groups.append({'access':access,'split':split,'submitted':len(selected),'coverageBlocked':sum(r['blocked'] for r in selected),
                           'unresolved':sum(r['kind']=='unresolved' for r in selected),
                           'noMatchFalsePositives':sum(r['kind']=='noMatch' and r['returnedCount']>0 for r in eligible),
                           'serviceErrors':sum(r['serviceError']=='serviceError' for r in eligible),'engineInvocations':sum(r['engineInvoked'] for r in selected),
                           'packSizes':selected[0]['packSizes'] if selected else {},'metrics':metrics,
                           'acceptance':'insufficient sample' if not sufficient else 'pass' if passed else 'fail'})
    return {'groups':groups,'caseDetailsSuppressed':True,'confidenceMeaning':'Relative match strength, not calibrated probability; small samples do not establish independent quality.'}

def evaluate(directory, swift):
    directory=private_directory(directory)
    manifest=json.loads((directory/'manifest.json').read_text())
    require(manifest['state']==lock_state(), 'Candidate/configuration changed since freeze')
    require(manifest['protocolSHA256']==digest(PROTOCOL.read_bytes()), 'Protocol changed')
    require(manifest['casesSHA256']==digest((directory/'cases.json').read_bytes()), 'Frozen cases changed')
    # Revalidate provenance and regenerate cases: exposure cannot be changed silently.
    require(manifest['provenanceSHA256']==digest((directory/'provenance.json').read_bytes()), 'Frozen provenance changed')
    source=json.loads((directory/'provenance.json').read_text())
    require(validate(source)==json.loads((directory/'cases.json').read_text())['cases'], 'Provenance changed; create a new version')
    env=dict(os.environ,DIVEID_INDEPENDENT_INPUT=str(directory/'cases.json'),DIVEID_INDEPENDENT_OUTPUT=str(directory/'private-results.json'))
    require(not (directory/'private-results.json').exists(), 'Baseline already run; preserve it')
    with (directory/'private-run.log').open('x') as log:
        os.chmod(log.name,0o600)
        result=subprocess.run([swift,'test','--jobs','4','--filter','testIndependentCustodianBaseline'],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT)
    require(result.returncode==0 and (directory/'private-results.json').exists(), 'Runner failed; custodian must inspect private log')
    require(manifest['state']==lock_state(), 'Candidate changed during evaluation')
    require(manifest['casesSHA256']==digest((directory/'cases.json').read_bytes()), 'Cases changed during evaluation')
    raw=json.loads((directory/'private-results.json').read_text())
    cases=json.loads((directory/'cases.json').read_text())['cases']
    expected={(c['id'], access) for c in cases for access in ('experimentalDevelopment','publication')}
    require(len(raw['rows'])==len(expected) and {(r['id'],r['access']) for r in raw['rows']}==expected, 'Incomplete runner output')
    report=aggregate(raw['rows']);report['frozenManifest']=manifest
    report['toolchain']=subprocess.check_output([swift,'--version'],text=True).strip()
    save_new(directory/'aggregate.json',report)
    return report

def main():
    p=argparse.ArgumentParser();p.add_argument('command',choices=['freeze','evaluate']);p.add_argument('--source',type=Path);p.add_argument('--private-dir',type=Path,required=True);p.add_argument('--swift',default='swift');a=p.parse_args()
    try:
        result=freeze(a.source,a.private_dir) if a.command=='freeze' else evaluate(a.private_dir,a.swift)
        print(json.dumps(result,indent=2))
    except (ValueError,KeyError,TypeError,AttributeError,OSError,subprocess.SubprocessError) as error:
        # No source text or identifiers echoed from parser exceptions.
        print('Import/evaluation blocked; check schema, provenance, permissions and frozen-state requirements.')
        return 1
    return 0

if __name__=='__main__':raise SystemExit(main())
