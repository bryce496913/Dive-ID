#!/usr/bin/env python3
"""Repeatably build the reviewed Tropical Pacific starter pack from the source workbook.

Requires Python 3 and openpyxl (`python -m pip install -r Tools/CatalogImport/requirements.txt`).
The importer never copies Media rows: workbook photographs are reference-only and unlicensed.
"""
from __future__ import annotations
import argparse, csv, json, re
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from openpyxl import load_workbook

PACK_SIZE = 40
COLORS = {'black','blue','brown','gray','green','olive','orange','red','silver','white','yellow'}
MARKINGS = {'barbels','beak','eye stripe','fin edge','patches','saddles','shell','spines','spots','stripes','tail','teeth'}
HABITATS = {'anemone','deep','lagoon','mangrove','open water','reef','rubble','sand','seagrass','shallow','surface','wall','wreck'}
BEHAVIORS = {'burrowing','cleaning','feeding','grazing','hiding','hovering','resting','schooling','solitary','swimming'}

def rows(sheet):
    it=sheet.iter_rows(values_only=True); header=[str(x) for x in next(it)]
    return [dict(zip(header,r)) for r in it if any(x is not None for x in r)]
def terms(text, vocabulary):
    low=text.lower(); out=[]
    for v in sorted(vocabulary):
        variants={v, v.rstrip('s'), v+'s'}
        if any(re.search(r'(?<![a-z])'+re.escape(x)+r'(?![a-z])',low) for x in variants): out.append(v)
    return out
def clean(value): return re.sub(r'\s+',' ',str(value or '')).strip()
def iso_date(value):
    if value is None: return None
    if hasattr(value,'isoformat'):
        result=value.isoformat().replace('+00:00','Z')
        return result + 'T00:00:00Z' if len(result) == 10 else (result if result.endswith('Z') else result + 'Z')
    result=str(value)
    return result + 'T00:00:00Z' if re.fullmatch(r'\d{4}-\d{2}-\d{2}', result) else result

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--workbook',default='DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx'); ap.add_argument('--output',default='DiveID/Resources/IdentificationPacks/TropicalPacific'); ap.add_argument('--report',default='Reports/TropicalPacificImportReport.json'); ap.add_argument('--exclusions',default='Reports/TropicalPacificExclusions.csv'); a=ap.parse_args()
    wb=load_workbook(a.workbook,data_only=True,read_only=True)
    creatures=rows(wb['Creatures']); traits=defaultdict(list); sources={};
    for x in rows(wb['Traits']): traits[x['creature_id']].append(x)
    for x in rows(wb['Sources']):
        if x['creature_id']: sources[x['creature_id']]=x
    eligible=[]; excluded=[]
    for c in creatures:
        reasons=[]; cid=clean(c['creature_id']); ts=[t for t in traits[cid] if clean(t['trait_type']) in ('identification_description','variation_description')]
        if clean(c['occurrence_status'])!='presence_supported': reasons.append('regional occurrence is not source-supported')
        if clean(c['identity_confidence'])!='high' or float(c['identity_confidence_score'] or 0)<100: reasons.append('identity confidence is below the starter-pack threshold')
        if clean(c['text_transcription_confidence'])!='high': reasons.append('account transcription confidence is not high')
        if not clean(c['common_name']) or not clean(c['scientific_name_printed']): reasons.append('identity is incomplete')
        if not ts: reasons.append('no identification trait transcription')
        elif not any(clean(t['transcription_confidence'])=='high' for t in ts): reasons.append('identification traits are not high-confidence transcriptions')
        if cid not in sources: reasons.append('species-account provenance is missing')
        if reasons: excluded.append((cid,clean(c['common_name']),'; '.join(reasons)))
        else: eligible.append(c)
    # Stable, broad initial sample: source page then UUID. No subjective quality ranking.
    selected=sorted(eligible,key=lambda c:(int(c['source_book_page'] or 99999),clean(c['creature_id'])))[:PACK_SIZE]
    selected_ids={c['creature_id'] for c in selected}
    for c in eligible:
        if c['creature_id'] not in selected_ids: excluded.append((c['creature_id'],clean(c['common_name']),'eligible but outside the deterministic 40-record starter-pack limit'))
    profiles=[]
    for c in selected:
        cid=c['creature_id']; s=sources[cid]
        source_traits=[clean(t['value']) for t in traits[cid] if clean(t['value']) and clean(t['transcription_confidence'])=='high']
        trait=' '.join(source_traits); family=clean(c['family_printed_raw'])
        profile={'id':cid,'commonName':clean(c['common_name']),'scientificName':clean(c['scientific_name_printed']),'aliases':[],
          'categories':['fish'],'colors':terms(trait,COLORS),'markings':terms(trait,MARKINGS),'bodyShapes':[],
          'habitats':terms(trait,HABITATS),'regions':['indo-pacific','pacific'],'behaviors':terms(trait,BEHAVIORS),'keywords':[],
          'minimumSizeCentimeters':None,'maximumSizeCentimeters':c['max_size_cm'],'minimumDepthMeters':c['depth_min_m'],'maximumDepthMeters':c['depth_max_m'],
          'summary':source_traits[0],'distinguishingFeatures':source_traits,'typicalHabitat':'','geographicRange':clean(c['range_detail_raw']),
          'cautions':[],'imageAssetName':None,'regionalOccurrence':'regular','regionalOccurrenceNotes':clean(c['occurrence_basis']),'subregions':[],
          'appearanceVariants':[],'similarSpecies':[],'bundledImage':None,
          'dataSources':[{'stableSourceID':clean(s['source_id']),'sourceName':clean(s['citation']),'sourceURL':clean(s['species_specific_url']),'citationReference':clean(s['source_locator']),'reviewedFields':[x.strip() for x in clean(s['supported_fields']).split(';') if x.strip()],'accessedDate':iso_date(s['accessed_date']),'sourceLicense':clean(s['licence'])}],
          'review':{'status':'draft','reviewerNotes':'Imported from high-confidence workbook transcription; external taxonomy and independent source review remain required.','reviewDate':None,'verifiedBy':None},
          'taxonomy':{'wormsAphiaID':c['aphia_id'],'scientificNameAuthority':None,'taxonomicClass':None,'order':None,'family':family or None,'genus':clean(c['scientific_name_printed']).split()[0],'acceptedScientificName':clean(c['scientific_name_printed']),'sourceScientificName':clean(c['scientific_name_printed'])},
          'measurements':{'typicalObservedMinimumCentimeters':None,'typicalObservedMaximumCentimeters':None,'maximumRecordedCentimeters':c['max_size_cm'],'type':'totalLength'},
          'tailShape':None,'mouthAndHeadShape':[],'finAndSpineClues':[]}
        profiles.append(profile)
    out=Path(a.output); out.mkdir(parents=True,exist_ok=True)
    (out/'Creatures.json').write_text(json.dumps(profiles,indent=2,ensure_ascii=False)+'\n')
    manifest={'id':'tropical-pacific','schemaVersion':1,'packVersion':1,'displayName':'Tropical Pacific','shortDescription':'A source-traceable offline Tropical Pacific starter catalogue','geographicScope':'Tropical Indo-Pacific reef-fish accounts whose workbook occurrence is supported by the cited book distribution statement.','regionAliases':['Tropical Pacific','Pacific','Indo-Pacific','Fiji','Hawaii','Australia','Philippines','Indonesia'],'speciesCount':len(profiles),'speciesResourceName':'Creatures','imageSubdirectory':'Images','includedWithApp':True,'lastDataReviewDate':None}
    (out/'PackManifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    report={'workbook':a.workbook,'selectionPolicy':{'packSize':PACK_SIZE,'rules':['presence_supported occurrence','high identity confidence with score 100','high text transcription confidence','high-confidence identification trait','species-account provenance']},'selectedCount':len(profiles),'excludedCount':len(excluded),'selectedIDs':[p['id'] for p in profiles],'mediaImported':0,'mediaPolicy':'All workbook media is reference_only_not_licensed_for_app and is not imported.','unsupportedFieldsPolicy':'Unsupported values remain null, empty strings, or empty arrays; no taxonomy, typical size, image, alias, caution, or comparison is inferred.'}
    Path(a.report).write_text(json.dumps(report,indent=2)+'\n')
    with Path(a.exclusions).open('w',newline='') as f:
        w=csv.writer(f); w.writerow(['creature_id','common_name','exclusion_reason']); w.writerows(sorted(excluded))
    print(f"wrote {len(profiles)} records; reported {len(excluded)} exclusions")
if __name__=='__main__': main()
