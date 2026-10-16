#!/usr/bin/env python3
"""Validate field evidence and assemble eligible draft staging profiles, never packs."""
import hashlib
import json
import sys
from collections import defaultdict
from datetime import date
from urllib.parse import urlparse
from intake import ROOT, DATA, atomic_json, intake, normalize, read_csv
from worms import payload_hash
sys.path.insert(0,str(ROOT/'Tools/CatalogReview'))
from catalogue_validation import validate_catalogue, VOCABULARY
from catalog_review import content_fingerprint

TEXT_FIELDS={'commonName','appearance','morphology','habitat','distribution','lifeStages'}
FIELDS=TEXT_FIELDS | {'categories','measurements','depth','lookalikes','region.caribbean','region.tropical-pacific'}
REQUIRED={'commonName','categories','appearance','habitat','distribution'}


def validate_evidence(rows, candidates):
    by_id={r['candidateID']:r for r in candidates}
    fingerprints=set()
    for row in rows:
        if row.get('schemaVersion') != 1 or row.get('candidateID') not in by_id:
            raise ValueError('Unknown evidence candidate or schema')
        if normalize(row.get('sourceScientificName','')) != normalize(by_id[row['candidateID']]['scientificNameInput']):
            raise ValueError('Evidence must identify the specific candidate species')
        if row.get('field') not in FIELDS or row.get('evidenceStatus') not in ('supported','conflicting','unsupported'):
            raise ValueError('Unknown field or evidence status')
        if row.get('humanReviewer') is not None:
            raise ValueError('Research ledger is not a human publication decision; use existing overlay')
        url=urlparse(row.get('sourceURL',''))
        if url.scheme!='https' or not url.hostname or not url.path.strip('/'):
            raise ValueError('Evidence needs an exact species-specific HTTPS account URL')
        for key in ('sourceSection','note','researchMethod'):
            if not isinstance(row.get(key),str) or not row[key].strip():raise ValueError(f'Missing evidence {key}')
        date.fromisoformat(row['accessedDate'])
        fingerprint=row.get('evidenceFingerprint')
        if fingerprint != payload_hash({k:v for k,v in row.items() if k!='evidenceFingerprint'}) or fingerprint in fingerprints:
            raise ValueError('Duplicate or modified evidence fingerprint')
        fingerprints.add(fingerprint)
        field,value=row['field'],row.get('value')
        if field in TEXT_FIELDS and (not isinstance(value,str) or not value.strip()):raise ValueError('Text evidence must be nonempty')
        if field=='categories' and (not isinstance(value,list) or not value or not all(isinstance(v,str) for v in value)):raise ValueError('Categories must be a nonempty array')
        if field.startswith('region.') and (not isinstance(value,dict) or value.get('occurrence')!='documented' or not isinstance(value.get('localities'),list) or not value['localities'] or not all(isinstance(x,str) and x.strip() for x in value['localities'])):
            raise ValueError('Region evidence requires documented species-specific named localities')
        if field=='measurements' and row['evidenceStatus']=='supported':
            if not isinstance(value,dict) or value.get('type') not in ('totalLength','forkLength','discWidth','carapaceLength'):
                raise ValueError('Supported size needs explicit measurement type')
            maximum=value.get('maximumRecordedCentimeters')
            if type(maximum) not in (int,float) or not 0 < maximum < float('inf'):raise ValueError('Invalid measured size')
        if field=='depth' and row['evidenceStatus']=='supported':
            if not isinstance(value,dict) or any(type(value.get(k)) not in (int,float) for k in ('minimumMeters','maximumMeters')) or not 0 <= value['minimumMeters'] <= value['maximumMeters'] < float('inf'):
                raise ValueError('Invalid supported depth bounds')
    return rows


def summarize_fields(rows):
    grouped=defaultdict(list)
    for row in rows:grouped[row['field']].append(row)
    supported,conflicts={},[]
    for field,items in sorted(grouped.items()):
        values={payload_hash(r['value']) for r in items if r['evidenceStatus']=='supported'}
        if any(r['evidenceStatus']=='conflicting' for r in items) or len(values)>1:
            conflicts.append(field)
        elif len(values)==1:
            supported[field]=next(r['value'] for r in items if r['evidenceStatus']=='supported')
    return supported,conflicts


def assemble_profile(canonical, source_name, fields, rows):
    # Non-app evidence fields (life stages/lookalikes) remain in the ledger until
    # typed variants and canonical comparison IDs receive specific review.
    regions=['caribbean' if r=='region.caribbean' else 'pacific' for r in fields if r.startswith('region.')]
    record={'id':canonical['speciesID'],'commonName':fields['commonName'],'scientificName':canonical['acceptedScientificName'],
            'aliases':[], 'categories':fields['categories'],'colors':[],'markings':[],'bodyShapes':[], 'habitats':[], 'regions':sorted(regions),
            'behaviors':[],'keywords':[],'minimumSizeCentimeters':None,'maximumSizeCentimeters':None,
            'minimumDepthMeters':(fields.get('depth') or {}).get('minimumMeters'),'maximumDepthMeters':(fields.get('depth') or {}).get('maximumMeters'),
            'summary':fields['appearance'],'distinguishingFeatures':[fields.get('morphology', fields['appearance'])],
            'typicalHabitat':fields['habitat'],'geographicRange':fields['distribution'],'cautions':[],
            'regionalOccurrence':'unknown','subregions':[],'appearanceVariants':[],'similarSpecies':[],
            'imageAssetName':None,'bundledImage':None,'review':{'status':'draft','verifiedBy':None,'reviewDate':None,'reviewerNotes':None},
            'taxonomy':{'wormsAphiaID':int(canonical['acceptedAphiaID']),'acceptedScientificName':canonical['acceptedScientificName'],
                        'sourceScientificName':source_name,'scientificNameAuthority':canonical.get('authority') or None,
                        'taxonomicClass':canonical.get('class') or None,**{k:canonical.get(k) or None for k in ('genus','family','order')}},
            'measurements':fields.get('measurements'),'dataSources':[]}
    for row in rows:
        if row['evidenceStatus']=='supported':
            record['dataSources'].append({'stableSourceID':'GLOBAL-'+row['evidenceFingerprint'][:16],
                'sourceName':urlparse(row['sourceURL']).hostname,'sourceURL':row['sourceURL'],'citationReference':row['sourceSection'],
                'reviewedFields':[row['field']],'accessedDate':row['accessedDate']+'T00:00:00Z','sourceLicense':None})
    return record


def stage(candidates, canonical, rows, baseline_complete):
    validate_evidence(rows,candidates)
    by_candidate=defaultdict(list)
    for row in rows:by_candidate[row['candidateID']].append(row)
    taxa={cid:taxon for taxon in canonical for cid in taxon['sourceCandidateIDs'].split(';')}
    packets,profiles,regions=[],[],[]
    emitted=set()
    for candidate in candidates:
        cid=candidate['candidateID'];evidence=by_candidate.get(cid,[])
        fields,conflicts=summarize_fields(evidence)
        reasons=[]
        if cid not in taxa:reasons.append('taxonomy_pending')
        if not baseline_complete:reasons.append('baseline_synonym_comparison_pending')
        if REQUIRED-set(fields):reasons.append('missing_identification_evidence')
        if conflicts:reasons.append('conflicting_source_fields')
        categories=fields.get('categories',[])
        if candidate['requiresCategorySchemaReview']=='yes' or any(c not in VOCABULARY['categories'] for c in categories):reasons.append('category_schema_review')
        documented=[field.split('.',1)[1] for field in fields if field.startswith('region.')]
        if not documented:reasons.append('no_supported_regional_assignment')
        if evidence:
            packet={'candidateID':cid,'sourceScientificName':candidate['scientificNameInput'],'supportedFields':fields,
                    'conflictingFields':conflicts,'missingCoreFields':sorted(REQUIRED-set(fields)),
                    'evidenceFingerprints':[r['evidenceFingerprint'] for r in evidence], 'blockingReasons':reasons,
                    'reviewStatus':'draft','humanApprovalCoversCurrentContent':False}
            packet['researchContentFingerprint']=payload_hash(packet)
            packets.append(packet)
            regions.append({'candidateID':cid,'documentedRegions':documented,'regionalExportEligible':not reasons,'blockingReasons':reasons})
        if not reasons and taxa[cid]['speciesID'] not in emitted:
            profile=assemble_profile(taxa[cid],candidate['scientificNameInput'],fields,evidence)
            validate_catalogue([profile]);profiles.append(profile);emitted.add(profile['id'])
    validate_catalogue(profiles)
    return packets,profiles,{'schemaVersion':1,'primaryCandidates':len(candidates),'candidatesWithInspectedEvidence':len(packets),
           'candidatesWithoutInspectedEvidence':len(candidates)-len(packets),'regionEligibleProfiles':len(profiles),
           'evidenceCompleteDraftProfiles':len(profiles),'humanVerifiedNewProfiles':0,'publicationEligibleNewProfiles':0,
           'existingPublicationEligibleProfiles':2,'details':regions,
           'policy':'No app export. Candidate-set approval does not cover newly assembled content. Use validated existing review overlay after exact-content review.'}


def main():
    candidates,reserves,_,_,_=intake()
    rows=[json.loads(line) for line in (DATA/'EnrichmentEvidence.jsonl').read_text().splitlines() if line.strip()]
    canonical=read_csv(DATA/'CanonicalTaxa.csv')
    resolution=json.loads((ROOT/'Reports/GlobalMarine4000Resolution.json').read_text())
    packets,profiles,report=stage(candidates+reserves,canonical,rows,resolution['baselineTaxonomyComplete'])
    report['primaryCandidates']=len(candidates);report['reserveCandidates']=len(reserves)
    report['candidatesWithoutInspectedEvidence']=len(candidates)-sum(p['candidateID'] in {c['candidateID'] for c in candidates} for p in packets)
    # Derive existing eligibility instead of assuming the historical baseline forever.
    existing=[r for p in ROOT.glob('DiveID/Resources/IdentificationPacks/*/Creatures.json') for r in json.loads(p.read_text())]
    report['existingPublicationEligibleProfiles']=sum(r.get('review',{}).get('status')=='verified' and bool(r.get('categories')) for r in existing)
    report['draftProfileFingerprints']={r['id']:content_fingerprint(r) for r in profiles}
    atomic_json(DATA/'EnrichmentStaging.json',packets)
    atomic_json(DATA/'DraftProfiles.json',profiles)
    atomic_json(ROOT/'Reports/GlobalMarine4000RegionEligibility.json',report)
    print(json.dumps({k:v for k,v in report.items() if k not in ('details','draftProfileFingerprints')},sort_keys=True))

if __name__=='__main__':main()
