"""Derive the Release oracle from recorded human decisions, never from catalogue status alone."""
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


def generate_archived():
    """The oracle for the archived v3 packs (Data/CatalogArchive/v3), from the decision
    documents that approved them. Kept so the October 2026 evidence stays checkable."""
    result = {}
    for catalogue, directory, decisions in [
        ('caribbean', 'Caribbean', 'CaribbeanReviewDecisions.json'),
        ('tropical-pacific', 'TropicalPacific', 'ReviewDecisions.json')
    ]:
        records = json.loads((ROOT / f'Data/CatalogArchive/v3/{directory}/Creatures.json').read_text())
        document = json.loads((ROOT / 'Data/CatalogReview' / decisions).read_text())
        result[catalogue] = approved_ids(records, document, catalogue)
    return result


# Every bundled pack is FishBase-built and shares record text, so approvals come from one
# place: the Global batch decisions (Data/CatalogReview/GlobalBatches). The decision
# documents above (`approved_ids`) remain the oracle for the archived v3 packs only.
PACKS = (('caribbean', 'Caribbean'), ('tropical-pacific', 'TropicalPacific'), ('global', 'Global'))


def approved_from_batches(records, root, validate=True):
    """IDs whose current content a recorded batch approval covers. The pack's verified
    records must be exactly these, carrying exactly the review that approval produces."""
    import global_batches
    if validate:
        validate_catalogue(records)
    reviews, _ = global_batches.approved_reviews(records, root)
    for record in records:
        if record['id'] in reviews and record['review'] != reviews[record['id']]:
            raise ValueError(f"Review evidence differs from the recorded approval: {record['id']}")
        if record['id'] in reviews and not record.get('categories'):
            raise ValueError(f"Approval does not cover current content: {record['id']} has no category")
    actual = {record['id'] for record in records if record['review']['status'] == 'verified'}
    if actual != set(reviews):
        raise ValueError(f"Publication differs from approvals: {sorted(actual ^ set(reviews))}")
    return sorted(reviews)


def generate(root=None):
    import global_batches
    root = root or global_batches.BATCHES
    return {catalogue: approved_from_batches(
                json.loads((ROOT / f'DiveID/Resources/IdentificationPacks/{directory}/Creatures.json').read_text()), root)
            for catalogue, directory in PACKS}


if __name__ == '__main__':
    (ROOT / 'DiveIDTests/Fixtures/PublicationApprovedIDs.json').write_text(json.dumps(generate(), indent=2) + '\n')
