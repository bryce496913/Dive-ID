#!/usr/bin/env python3
"""Import Dive ID "Share my feedback" files into a private pilot holdout (independent-v1,
in-app collection revision 2026-10-28).

    python3 Tools/Evaluation/import_feedback.py --holdout ~/DiveID-holdout/diver-pilot-v1 FILE...

Each shared file is validated as a whole (format diveid-diver-feedback, schemaVersion 1);
an invalid file imports nothing. A record qualifies only as IndependentProtocol.v1.json
`inAppCollection.qualifies` says: evaluation consent, the first search of the install with
no prior exposure, not a re-search or edited after results, searched in Global. Qualifying
"None of these" and "Not sure" records are imported like the rest; no record is chosen by
engine success or by the diver's answer. Records are de-duplicated by feedbackID.

The holdout directory must be outside this repository (mode 0700, files 0600). It holds:
- submissions.json: qualifying records with the description verbatim. The diver's
  answer is kept as contributorClaimedIdentity, and shownResults privately; both are
  engine-exposed and are never labels.
- curator-worksheet.csv: description and the diver's optional details only, with no
  engine results, ranks or claims, and blank columns for the curator.
- intake-log.json: every record seen, its decision and reason. No descriptions.

The output is counts only: no wording, identities or results.
"""
import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import os
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROTOCOL = ROOT / 'Data/Evaluation/IndependentProtocol.v1.json'
FORMAT, SCHEMA_VERSION = 'diveid-diver-feedback', 1
ANSWERS = {'claimedSpecies', 'none', 'notSure'}
REQUIRED = {
    'feedbackID': str, 'attemptID': str, 'createdAt': str, 'appVersion': str, 'appBuild': str, 'buildChannel': str,
    'packID': str, 'catalogueVersion': int, 'participantCode': str, 'originalDescription': str,
    'firstSearchOfInstall': bool, 'editedAfterSeeingResults': bool, 'shownResults': list, 'answer': str,
    'hasPhotoToSend': bool, 'consentForEvaluation': bool, 'consentForPublication': bool, 'priorExposure': bool,
}
WORKSHEET_COLUMNS = ['feedbackID', 'participantID', 'collectionDate', 'description', 'broadRegion', 'approximateDepth',
                     'uncertainty', 'hasPhotoToSend', 'expectedSpeciesIDs', 'acceptableSpeciesIDs', 'evidenceReferences',
                     'curatorID', 'adjudicationDate', 'notes']


class ImportError_(Exception):
    pass


def require(condition, message):
    if not condition:
        raise ImportError_(message)


def is_uuid(value):
    try:
        uuid.UUID(str(value))
        return True
    except ValueError:
        return False


def validate_file(data):
    """The parsed export, or ImportError_ naming the first problem. Nothing partial."""
    try:
        document = json.loads(data)
    except (ValueError, UnicodeDecodeError) as error:
        raise ImportError_(f'not JSON: {error}') from error
    require(isinstance(document, dict), 'not a feedback export object')
    require(document.get('format') == FORMAT, f'format is not {FORMAT}')
    require(document.get('schemaVersion') == SCHEMA_VERSION, f'unsupported schemaVersion {document.get("schemaVersion")!r}')
    require(isinstance(document.get('participantCode'), str), 'participantCode missing')
    require(isinstance(document.get('records'), list), 'records missing')
    for index, record in enumerate(document['records']):
        where = f'record {index}'
        require(isinstance(record, dict), f'{where} is not an object')
        for key, kind in REQUIRED.items():
            require(isinstance(record.get(key), kind) and not (kind is int and isinstance(record.get(key), bool)),
                    f'{where}: {key} missing or not {kind.__name__}')
        require(is_uuid(record['feedbackID']) and is_uuid(record['attemptID']), f'{where}: feedbackID/attemptID not UUIDs')
        require(record['answer'] in ANSWERS, f'{where}: unknown answer {record["answer"]!r}')
        require((record['answer'] == 'claimedSpecies') == is_uuid(record.get('claimedSpeciesID') or ''),
                f'{where}: claimedSpeciesID must accompany claimedSpecies only')
        require(record.get('researchOfAttemptID') is None or is_uuid(record['researchOfAttemptID']), f'{where}: bad researchOfAttemptID')
        require(record['participantCode'] == document['participantCode'], f'{where}: participantCode differs from the file')
        try:
            dt.datetime.fromisoformat(record['createdAt'].replace('Z', '+00:00'))
        except ValueError as error:
            raise ImportError_(f'{where}: createdAt is not ISO 8601') from error
    return document


def load_rules(protocol=PROTOCOL):
    return json.loads(Path(protocol).read_text())['inAppCollection']['qualifies']


def qualification(record, rules):
    """None when the record qualifies, else the reason. Never looks at results or the answer."""
    if record['consentForEvaluation'] is not rules['consentForEvaluation']:
        return 'no evaluation consent'
    if record['firstSearchOfInstall'] is not rules['firstSearchOfInstall'] or record['priorExposure'] is not rules['priorExposure']:
        return 'not the first search of the install (prior exposure)'
    if record.get('researchOfAttemptID') != rules['researchOfAttemptID'] or record['editedAfterSeeingResults'] is not rules['editedAfterSeeingResults']:
        return 're-search or edited after results were shown'
    if record['packID'] != rules['packID']:
        return f'searched in {record["packID"]}, not {rules["packID"]}'
    return None


def submission(record, source_sha, imported_at):
    """The private holdout row. contributorClaimedIdentity and shownResults are engine-exposed."""
    return {
        'feedbackID': record['feedbackID'], 'attemptID': record['attemptID'],
        'description': record['originalDescription'],  # verbatim: never trimmed or corrected
        'collectionDate': record['createdAt'][:10], 'region': record['packID'], 'language': None,
        'participantID': record['participantCode'], 'attestsOwnUnpromptedWords': None,
        'consentForEvaluation': record['consentForEvaluation'], 'consentForPublication': record['consentForPublication'],
        'priorExposure': record['priorExposure'],
        'observationContext': {key: record.get(key) for key in ('broadRegion', 'approximateDepth', 'uncertainty', 'hasPhotoToSend')},
        'contributorClaimedIdentity': {'answer': record['answer'], 'claimedSpeciesID': record.get('claimedSpeciesID'),
                                       'engineExposed': True, 'useAsLabel': False},
        'engineExposure': {'shownResults': record['shownResults'], 'catalogueVersion': record['catalogueVersion']},
        'app': {'version': record['appVersion'], 'build': record['appBuild'], 'channel': record['buildChannel']},
        'source': {'sourceFileSHA256': source_sha, 'importedAt': imported_at},
    }


def worksheet_csv(submissions):
    """Description and the diver's own optional details only: no engine output or claims."""
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=WORKSHEET_COLUMNS, lineterminator='\n')
    writer.writeheader()
    for row in sorted(submissions, key=lambda r: (r['collectionDate'], r['feedbackID'])):
        context = row['observationContext']
        depth = context.get('approximateDepth')
        writer.writerow({
            'feedbackID': row['feedbackID'], 'participantID': row['participantID'], 'collectionDate': row['collectionDate'],
            'description': row['description'], 'broadRegion': context.get('broadRegion') or '',
            'approximateDepth': f'{depth["value"]:g} {depth["unit"]}' if depth else '',
            'uncertainty': context.get('uncertainty') or '', 'hasPhotoToSend': 'yes' if context.get('hasPhotoToSend') else 'no',
        })
    return out.getvalue()


def holdout_directory(path, root=ROOT):
    path = Path(path).expanduser().resolve()
    require(not path.is_relative_to(Path(root).resolve()), 'The holdout must be outside the repository')
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(path.stat().st_mode & 0o077 == 0, 'The holdout directory must have mode 0700')
    return path


def write_private(path, text):
    temporary = path.with_suffix(path.suffix + '.tmp')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, 'w') as handle:
        handle.write(text)
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def run(files, holdout, rules, now=None, root=ROOT):
    """Import the files; returns counts. Raises ImportError_ only for a bad holdout."""
    directory = holdout_directory(holdout, root)
    imported_at = (now or dt.datetime.now(dt.timezone.utc)).isoformat()
    store_path, log_path = directory / 'submissions.json', directory / 'intake-log.json'
    store = json.loads(store_path.read_text()) if store_path.exists() else {
        'schemaVersion': 1, 'protocolVersion': 'independent-v1', 'source': 'in-app collection', 'submissions': []}
    log = json.loads(log_path.read_text()) if log_path.exists() else {'schemaVersion': 1, 'entries': []}
    known = {row['feedbackID'] for row in store['submissions']}
    counts = {'files': 0, 'invalidFiles': 0, 'records': 0, 'imported': 0, 'duplicates': 0, 'rejected': 0}
    for file in files:
        counts['files'] += 1
        data = Path(file).read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        try:
            document = validate_file(data)
        except ImportError_ as error:
            counts['invalidFiles'] += 1
            log['entries'].append({'sourceFile': Path(file).name, 'sourceFileSHA256': sha, 'at': imported_at,
                                   'decision': 'invalid file', 'reason': str(error)})
            continue
        for record in document['records']:
            counts['records'] += 1
            entry = {'feedbackID': record['feedbackID'], 'sourceFile': Path(file).name, 'sourceFileSHA256': sha, 'at': imported_at}
            if record['feedbackID'] in known:
                counts['duplicates'] += 1
                log['entries'].append({**entry, 'decision': 'duplicate', 'reason': 'feedbackID already imported or seen'})
                continue
            known.add(record['feedbackID'])
            reason = qualification(record, rules)
            if reason:
                counts['rejected'] += 1
                log['entries'].append({**entry, 'decision': 'not imported', 'reason': reason})
                continue
            store['submissions'].append(submission(record, sha, imported_at))
            counts['imported'] += 1
            log['entries'].append({**entry, 'decision': 'imported', 'reason': 'qualifies'})
    write_private(store_path, json.dumps(store, indent=2, ensure_ascii=False) + '\n')
    write_private(log_path, json.dumps(log, indent=2, ensure_ascii=False) + '\n')
    write_private(directory / 'curator-worksheet.csv', worksheet_csv(store['submissions']))
    counts['inHoldout'] = len(store['submissions'])
    return counts


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--holdout', required=True, type=Path, help='private directory outside the repository')
    parser.add_argument('files', nargs='+', type=Path, help='shared DiveID-feedback-*.json files')
    args = parser.parse_args(argv)
    try:
        counts = run(args.files, args.holdout, load_rules())
    except ImportError_ as error:
        print(f'error: {error}', file=sys.stderr)
        return 1
    print(json.dumps(counts, indent=2))
    return 0 if counts['invalidFiles'] == 0 else 2


if __name__ == '__main__':
    sys.exit(main())
