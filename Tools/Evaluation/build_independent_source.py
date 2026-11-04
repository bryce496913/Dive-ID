#!/usr/bin/env python3
"""Build the independent-v1 source document from an in-app holdout (custodian only).

    python3 Tools/Evaluation/build_independent_source.py --holdout ~/DiveID-holdout/diver-pilot-v1 \
        --dataset-version diver-pilot-v1 --pilot

Reads the holdout that import_feedback.py wrote: submissions.json (verbatim wording and
private provenance) and curator-worksheet.csv (the curator's labels, assigned without
engine output). Writes source.json in the same directory, ready for
`independent_divers.py preflight` and `freeze`. The output on screen is counts only.

Rules (IndependentProtocol.v1.json, IndependentDiverCollection.md):
- Wording comes from submissions.json, never the worksheet. A worksheet description that
  differs from the stored wording stops the build: descriptions are never edited.
- contributorClaimedIdentity and shownResults stay in private provenance. They are never
  copied into a label.
- A row without the diver's own-words attestation, or not confirmed English, is left out
  of the source and counted, not repaired.
- Labels name catalogue UUIDs. Each UUID must exist in the Global catalogue and match the
  curator's scientific name, so a wrong UUID cannot pass silently.
- A species the curator verified but the catalogue lacks is `outOfCatalogue`: it stays an
  unresolved label (excluded from quality denominators) because the protocol does not
  allow inferring noMatch from absence. It is counted separately.
- A blank labelKind is unresolved (not yet labelled).
- --pilot marks every row usedForDevelopment, as the pilot procedure requires.
"""
import argparse
import csv
import json
import sys
import uuid
from pathlib import Path

import import_feedback

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / 'DiveID/Resources/IdentificationPacks/Global/Creatures.json'
KINDS = ('identification', 'ambiguous', 'noMatch', 'regionConflict', 'unresolved')
YES, NO = {'yes', 'y', 'true'}, {'no', 'n', 'false', ''}


class BuildError(Exception):
    pass


def flag(value, column):
    text = (value or '').strip().casefold()
    if text in YES:
        return True
    if text in NO:
        return False
    raise BuildError(f'{column} must be yes or no')


def split_list(value, separator):
    return [item.strip() for item in (value or '').split(separator) if item.strip()]


def normalise_name(name):
    return ' '.join(name.casefold().split())


def load_catalogue(path=CATALOGUE):
    records = json.loads(Path(path).read_text())
    return {record['id'].lower(): normalise_name(record['scientificName']) for record in records}


def label(sheet, catalogue):
    """The label object for one row, or BuildError naming the problem (no wording or IDs in it)."""
    kind = (sheet.get('labelKind') or '').strip() or 'unresolved'
    if kind not in KINDS:
        raise BuildError('labelKind is not one of ' + ', '.join(KINDS))
    ids = []
    for value in split_list(sheet.get('expectedSpeciesIDs'), ';') + split_list(sheet.get('acceptableSpeciesIDs'), ';'):
        try:
            key = str(uuid.UUID(value))
        except ValueError as error:
            raise BuildError('a species ID is not a UUID') from error
        if key not in ids:
            ids.append(key)
    names = [normalise_name(name) for name in split_list(sheet.get('scientificNames'), ';')]
    out_of_catalogue = flag(sheet.get('outOfCatalogue'), 'outOfCatalogue')
    result = {'kind': kind, 'acceptableSpeciesIDs': ids}
    if out_of_catalogue:
        if kind != 'unresolved' or ids or not names:
            raise BuildError('outOfCatalogue needs labelKind unresolved, scientific names and no species IDs')
        if any(name in catalogue.values() for name in names):
            raise BuildError('an outOfCatalogue scientific name is in the catalogue: use its species ID')
    for key in ids:
        if key not in catalogue:
            raise BuildError('a species ID is not in the Global catalogue')
    if ids:
        if sorted(catalogue[key] for key in ids) != sorted(set(names)):
            raise BuildError('scientificNames do not match the catalogue names of the species IDs')
    if kind != 'unresolved':
        result.update({
            'verifierID': (sheet.get('curatorID') or '').strip(),
            'verificationDate': (sheet.get('adjudicationDate') or '').strip(),
            'verifiedWithoutAppResults': flag(sheet.get('verifiedWithoutAppResults'), 'verifiedWithoutAppResults'),
            'notes': (sheet.get('notes') or '').strip(),
            'evidenceReferences': split_list(sheet.get('evidenceReferences'), ';'),
        })
    else:
        result['notes'] = (sheet.get('notes') or '').strip()
    result['scientificNames'] = split_list(sheet.get('scientificNames'), ';')
    result['outOfCatalogue'] = out_of_catalogue
    return result


def observation(submission, sheet, catalogue, pilot):
    if sheet.get('description') != submission['description']:
        raise BuildError('worksheet description differs from the stored wording')
    context = dict(submission['observationContext'])
    context['suppliedPhotoFile'] = sheet.get('suppliedPhotoFile') or None
    context['suppliedPhotoSHA256'] = sheet.get('suppliedPhotoSHA256') or None
    return {
        'observationID': submission['feedbackID'],
        'description': submission['description'],
        'collectionDate': submission['collectionDate'],
        'region': submission['region'],
        'language': 'en',
        'author': {'kind': 'human', 'participantID': submission['participantID'], 'attestsOwnUnpromptedWords': True},
        'consentForEvaluation': submission['consentForEvaluation'],
        'consentForPublication': submission['consentForPublication'],
        'cohortID': (sheet.get('cohortID') or '').strip() or 'cohort-' + submission['participantID'],
        'encounterID': (sheet.get('encounterID') or '').strip() or 'encounter-' + submission['feedbackID'],
        'priorExposure': submission['priorExposure'],
        'usedForDevelopment': True if pilot else flag(sheet.get('usedForDevelopment'), 'usedForDevelopment'),
        'observationContext': context,
        'label': label(sheet, catalogue),
        # Private provenance. Engine-exposed: never a label, never shown to the curator.
        'contributorClaimedIdentity': submission['contributorClaimedIdentity'],
        'engineExposure': submission['engineExposure'],
        'app': submission['app'],
        'source': submission['source'],
    }


def build(holdout, dataset_version, pilot, catalogue=None, root=ROOT):
    directory = import_feedback.holdout_directory(holdout, root)
    submissions = json.loads((directory / 'submissions.json').read_text())['submissions']
    worksheet = import_feedback.read_worksheet(directory / 'curator-worksheet.csv')
    catalogue = catalogue if catalogue is not None else load_catalogue()
    observations, excluded, errors = [], {}, {}
    for submission in submissions:
        sheet = worksheet.get(submission['feedbackID'])
        reason = None
        if sheet is None:
            reason = 'not in the curator worksheet'
        elif (sheet.get('language') or '').strip().casefold() != 'en':
            reason = 'language not confirmed English (kept outside the v1 cohort)'
        elif not flag(sheet.get('attestsOwnUnpromptedWords'), 'attestsOwnUnpromptedWords'):
            reason = 'own-words attestation not obtained'
        if reason:
            excluded[reason] = excluded.get(reason, 0) + 1
            continue
        try:
            observations.append(observation(submission, sheet, catalogue, pilot))
        except BuildError as error:
            errors[str(error)] = errors.get(str(error), 0) + 1
    if errors:
        raise BuildError('worksheet problems, nothing written: ' + json.dumps(errors, sort_keys=True))
    document = {'schemaVersion': 1, 'protocolVersion': 'independent-v1', 'datasetVersion': dataset_version,
                'observations': observations}
    import_feedback.write_private(directory / 'source.json', json.dumps(document, indent=2, ensure_ascii=False) + '\n')
    kinds = [row['label']['kind'] for row in observations]
    return {
        'submissions': len(submissions), 'inSource': len(observations), 'excluded': excluded,
        'identifiable': kinds.count('identification'), 'ambiguous': kinds.count('ambiguous'),
        'noMatch': kinds.count('noMatch'), 'regionConflict': kinds.count('regionConflict'),
        'unresolved': kinds.count('unresolved'),
        'outOfCatalogue': sum(row['label']['outOfCatalogue'] for row in observations),
        'distinctContributors': len({row['author']['participantID'] for row in observations}),
        'cohorts': len({row['cohortID'] for row in observations}),
        'usedForDevelopment': sum(row['usedForDevelopment'] for row in observations),
        'source': str(directory / 'source.json'), 'caseDetailsSuppressed': True,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--holdout', required=True, type=Path, help='the private holdout import_feedback.py wrote')
    parser.add_argument('--dataset-version', required=True, help='immutable cohort version, e.g. diver-pilot-v1')
    parser.add_argument('--pilot', action='store_true', help='mark every row usedForDevelopment (the pilot procedure)')
    args = parser.parse_args(argv)
    try:
        counts = build(args.holdout, args.dataset_version, args.pilot)
    except (BuildError, import_feedback.ImportError_, OSError, KeyError, ValueError) as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    print(json.dumps(counts, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
