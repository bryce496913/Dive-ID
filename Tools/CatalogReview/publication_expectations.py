"""Derive the Release oracle from valid decisions, never from catalogue status alone."""
import json
from pathlib import Path
from catalog_review import validate_decisions, content_fingerprint, source_identity
from catalogue_validation import validate_catalogue

ROOT = Path(__file__).resolve().parents[2]


def approved_ids(records, document, catalogue):
    validate_catalogue(records)
    items = validate_decisions(records, document, catalogue)
    by_id = {record['id']: record for record in records}
    expected = []
    for item in items:
        if item['decision'] != 'verified':
            continue
        record = by_id[item['speciesID']]
        if (item.get('unresolvedQuestions') or not record.get('categories')
                or item['reviewedContentFingerprint'] != content_fingerprint(record)
                or not set(map(tuple, item['sourceIdentity'])).issubset(set(source_identity(record)))):
            raise ValueError(f"Approval does not cover current content: {record['id']}")
        for decision_key, review_key in [('reviewerIdentity', 'verifiedBy'),
                                         ('reviewDate', 'reviewDate'), ('reviewerNotes', 'reviewerNotes')]:
            if item[decision_key] != record['review'].get(review_key):
                raise ValueError(f"Review evidence differs: {record['id']} {review_key}")
        expected.append(record['id'])
    actual = {record['id'] for record in records if record['review']['status'] == 'verified'}
    if actual != set(expected):
        raise ValueError(f"Publication differs from approvals: {actual ^ set(expected)}")
    return sorted(expected)


def generate():
    result = {}
    for catalogue, directory, decisions in [
        ('caribbean', 'Caribbean', 'CaribbeanReviewDecisions.json'),
        ('tropical-pacific', 'TropicalPacific', 'ReviewDecisions.json')
    ]:
        records = json.loads((ROOT / f'DiveID/Resources/IdentificationPacks/{directory}/Creatures.json').read_text())
        document = json.loads((ROOT / 'Data/CatalogReview' / decisions).read_text())
        result[catalogue] = approved_ids(records, document, catalogue)
    return result


if __name__ == '__main__':
    (ROOT / 'DiveIDTests/Fixtures/PublicationApprovedIDs.json').write_text(json.dumps(generate(), indent=2) + '\n')
