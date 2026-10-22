#!/usr/bin/env python3
"""Bind inspected source evidence to current content; never manufacture approval."""
import json
from pathlib import Path
from catalog_review import content_fingerprint, source_identity, PUBLICATION_FIELDS
from publication_expectations import generate_archived as publication_expectations

ROOT = Path(__file__).resolve().parents[2]


def generate():
    publication_expectations()  # Reject status-only promotions or stale review evidence.
    evidence = json.loads((ROOT / 'Data/CatalogReview/SourceInspectionEvidence.json').read_text())
    packs = {}
    counts = {}
    for key, directory in [('caribbean', 'Caribbean'), ('tropical-pacific', 'TropicalPacific')]:
        records = json.loads((ROOT / f'Data/CatalogArchive/v3/{directory}/Creatures.json').read_text())
        packs[key] = {r['id']: r for r in records}
        counts[key] = {'included': len(records),
                      'humanReviewed': sum(r['review']['status'] in ('sourceChecked', 'verified') for r in records),
                      'approvedIDs': [r['id'] for r in records if r['review']['status'] == 'verified'],
                      'draft': sum(r['review']['status'] == 'draft' for r in records)}
    packets = []
    for inspection in evidence['records']:
        record = packs[inspection['pack']][inspection['speciesID']]
        packets.append({**inspection, 'reviewedContentFingerprint': content_fingerprint(record),
                        'sourceIdentity': [list(x) for x in source_identity(record)],
                        'currentContent': {key: record.get(key) for key in PUBLICATION_FIELDS},
                        'currentReview': record['review'],
                        'humanDecisionRequired': {
                            'decision': None, 'reviewerIdentity': None, 'reviewDate': None,
                            'reviewerNotes': None,
                            'instruction': 'Record an actual human decision covering this exact fingerprint; resolve every required question before verified. Source inspection and passing tests are not approval.'}})
        if record['review']['status'] == 'verified':
            packet = packets[-1]
            packet['resolvedHumanDecisions'] = packet['requiredHumanDecisions']
            packet['requiredHumanDecisions'] = []
            packet['humanDecisionRequired'] = None
            packet['humanDecision'] = {
                'decision': 'verified', 'reviewerIdentity': record['review']['verifiedBy'],
                'reviewDate': record['review']['reviewDate'], 'reviewerNotes': record['review']['reviewerNotes'],
                'reviewedContentFingerprint': content_fingerprint(record)}
            packet['sourceInspectionAssessmentNote'] = 'Earlier automated assessment retained as historical evidence; the explicit human decision above resolves its outstanding signoff requirements.'
    selected = {p['speciesID'] for p in packets}
    deferred = [{'speciesID': r['id'], 'commonName': r['commonName'], 'sourceReferences': r['dataSources'],
                 'reason': 'Full source inspection and human review still required.' +
                           (' Existing FishBase URL is a fish reference for a turtle; replace with an authoritative turtle account.' if r['commonName'] == 'Green Sea Turtle' else '')}
                for r in packs['caribbean'].values() if r['id'] not in selected]
    return {'schemaVersion': 2,
            'purpose': 'Source-inspected correction packets; not human publication decisions.',
            'counts': counts, 'records': packets, 'deferredCaribbeanRecords': deferred}


if __name__ == '__main__':
    (ROOT / 'Reports/CatalogueSourceReviewPass.json').write_text(json.dumps(generate(), indent=2, ensure_ascii=False) + '\n')
