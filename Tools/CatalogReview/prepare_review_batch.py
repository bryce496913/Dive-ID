#!/usr/bin/env python3
"""Generate the deliberately small first human-review packet without approving it."""
import csv, json
from pathlib import Path
from catalog_review import content_fingerprint, source_identity
ROOT=Path(__file__).resolve().parents[2]
CARIBBEAN=ROOT/'DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json'
PACIFIC=ROOT/'DiveID/Resources/IdentificationPacks/TropicalPacific/Creatures.json'
OUTCOMES=ROOT/'Reports/TropicalPacificOutcomes.csv'
OUTPUT=ROOT/'Reports/FirstCatalogueReviewBatch.json'

def fields(record):
    return {key:record.get(key) for key in ("commonName","scientificName","categories","summary","distinguishingFeatures","typicalHabitat","geographicRange","minimumSizeCentimeters","maximumSizeCentimeters","minimumDepthMeters","maximumDepthMeters")}
def packet(record, origin, row=None):
    sources=[]
    for s in record.get('dataSources',[]):
        sources.append({"stableSourceID":s.get('stableSourceID'),"sourceName":s.get('sourceName'),"sourceURL":s.get('sourceURL'),"citationReference":s.get('citationReference'),"reviewedFields":s.get('reviewedFields')})
    unresolved=[]
    original={"identificationText":record.get('distinguishingFeatures',[])}
    evidence=[]
    if row:
        original.update(sourceCategory=row['source_category'], identificationEvidence=row['identification_evidence'],
                        sourceTitleCommonOCR=row['source_title_common_ocr'], sourceTitleScientificOCR=row['source_title_scientific_ocr'])
        evidence.append({"field":"source row","value":f"workbook row {row['workbook_row']}; source {row['source_id']}; book page {row['source_book_page']}; PDF page {row['source_pdf_page']}; tile {row['source_tile']}"})
        unresolved.append(f"Category OCR {row['source_category']!r} is unreadable; inspect the cited original page before proposing a controlled category.")
    else:
        unresolved.append("Independent species-specific review of identity, traits, range, habitat, size, and source support is required.")
    return {"speciesID":record['id'],"sourceRowIdentity":({"workbook":"DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx","workbookRow":int(row['workbook_row']),"sourceID":row['source_id']} if row else {"catalogue":"caribbean-pack-3","stableSpeciesID":record['id']}),
      "pack":origin,"currentFields":fields(record),"sourceReferences":sources,"originalText":original,"proposedCorrections":{},
      "unresolvedQuestions":unresolved,"fieldEvidence":evidence,"reviewDecision":"draft","reviewerIdentity":None,"reviewDate":None,
      "reviewedContentFingerprint":content_fingerprint(record),"sourceIdentity":source_identity(record)}

def main():
    caribbean=json.loads(CARIBBEAN.read_text()); pacific=json.loads(PACIFIC.read_text())
    with OUTCOMES.open(newline='',encoding='utf-8') as f:
        rows=[r for r in csv.DictReader(f) if r['outcome']=='included' and r['category_diagnostic']]
    by_id={r['id']:r for r in pacific}
    packets=[packet(r,'caribbean') for r in caribbean]+[packet(by_id[r['creature_id']],'tropical-pacific',r) for r in rows]
    document={"schemaVersion":1,"purpose":"Human-review preparation only; no record in this packet is approved.",
      "sourcePageAvailability":"The repository contains workbook transcriptions and page/tile locators, but not the original source PDF pages. Category corrections remain unresolved until a reviewer inspects those pages.",
      "recordCounts":{"caribbean":len(caribbean),"tropicalPacificUnresolvedCategory":len(rows)},"records":packets}
    OUTPUT.write_text(json.dumps(document,indent=2,ensure_ascii=False)+'\n')
    print(f"wrote {len(packets)} review packets")
if __name__=='__main__': main()
