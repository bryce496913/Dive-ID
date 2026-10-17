"""Pinned global candidate intake. No application catalogue writes."""
import csv
import hashlib
import json
import io
import sys
import unicodedata
import openpyxl
import uuid
from collections import Counter, defaultdict
from pathlib import Path
from openpyxl import load_workbook

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'Data/GlobalMarine'
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, 'https://github.com/bryce496913/Dive-ID/global-marine')
WORMS_BASE = 'https://www.marinespecies.org/rest/'
BATCH_SIZE = 250
INPUT_SCHEMA = 2
# Bump when matching, taxonomy interpretation, ordering or intake policy changes.
DECISION_POLICY = 1
WORKBOOK = 'DiveID_Tropical_Pacific_Internal_Consistency_Cleaned.xlsx'
SUPPLEMENT = 'Data/TropicalPacific/TropicalPacificExpansion616.draft.json'


def fingerprint(manifest):
    content = json.dumps(manifest, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
    return hashlib.sha256(content).hexdigest()


def input_configuration():
    return {'decisionPolicyVersion': DECISION_POLICY, 'uuidNamespace': str(NAMESPACE),
            'wormsBaseURL': WORMS_BASE, 'batchSize': BATCH_SIZE,
            'pythonVersion': list(sys.version_info[:2]), 'unicodeVersion': unicodedata.unidata_version,
            'openpyxlVersion': openpyxl.__version__, 'workbookSheet': 'Creatures',
            'workbookReadOnly': True, 'workbookDataOnly': True}


class InputSnapshot:
    """Capture once, then parse and hash exactly those bytes (never reread paths)."""
    def __init__(self, root):
        self.root = Path(root)
        required = [WORKBOOK, *['Data/GlobalMarine/' + name for name in (
            'Expansion4000_CandidateQueue.csv', 'Expansion4000_ReserveQueue.csv',
            'Expansion4000_Audit.json', 'Sources/reef.csv', 'Sources/asfis.csv')]]
        pack_paths = {p.relative_to(self.root).as_posix()
                      for p in self.root.glob('DiveID/Resources/IdentificationPacks/*/*.json')}
        # The supplement and pack membership are optional, but their presence is
        # part of the baseline. Missing required inputs fail before any writes.
        self.content = {}
        for name in sorted(set(required) | pack_paths):
            try:
                self.content[name] = (self.root / name).read_bytes()
            except FileNotFoundError as error:
                raise ValueError(f'Intake input disappeared or is missing: {name}; restore the input and retry against a stable input tree. No checkpoint may be reused without the full baseline.') from error
        try:
            self.content[SUPPLEMENT] = (self.root / SUPPLEMENT).read_bytes()
        except FileNotFoundError:
            self.content[SUPPLEMENT] = None
        self.pack_paths = sorted(pack_paths)
        self.manifest = {'schemaVersion': INPUT_SCHEMA,
                         'files': {name: hashlib.sha256(data).hexdigest() if data is not None else None
                                   for name, data in sorted(self.content.items())},
                         'configuration': input_configuration()}

    def csv(self, name):
        return list(csv.DictReader(io.StringIO(self.content[name].decode('utf-8-sig'), newline='')))

    def json(self, name):
        return json.loads(self.content[name].decode('utf-8'))



def normalize(value):
    return ' '.join(value.split()).casefold()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + '\n')
    temp.replace(path)


def write_csv(path, rows, fields):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(path.suffix + '.tmp')
    with temp.open('w', newline='', encoding='utf-8') as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator='\n')
        writer.writeheader()
        writer.writerows(rows)
    temp.replace(path)


def existing_identities(root=ROOT, snapshot=None):
    snapshot = snapshot if snapshot is not None else InputSnapshot(root)
    by_name, by_id = defaultdict(set), defaultdict(set)
    workbook = load_workbook(io.BytesIO(snapshot.content[WORKBOOK]), read_only=True, data_only=True)
    values = iter(workbook['Creatures'].values)
    headers = next(values)
    rows = [dict(zip(headers, values)) for values in values]
    workbook.close()
    if len(rows) != 1650:
        raise ValueError('Expected all 1650 workbook identities')
    workbook_by_id = {}
    def add(sid, name):
        sid = str(uuid.UUID(sid))
        by_id[sid]  # Preserve identities with unreadable names without inventing one.
        if name and name.strip():
            by_name[normalize(name)].add(sid)
            by_id[sid].add(normalize(name))
    for row in rows:
        add(row['creature_id'], row['scientific_name_printed'])
        workbook_by_id[row['creature_id']] = row
    profiles = []
    paths = [p for p in snapshot.pack_paths if p.endswith('/Creatures.json')]
    if snapshot.content[SUPPLEMENT] is not None:
        paths.append(SUPPLEMENT)
    for path in paths:
        for profile in snapshot.json(path):
            add(profile['id'], profile['scientificName'])
            taxonomy = profile.get('taxonomy') or {}
            if taxonomy.get('acceptedScientificName'):
                add(profile['id'], taxonomy['acceptedScientificName'])
            if 'IdentificationPacks' in str(path):
                profiles.append(profile)
    return by_name, by_id, workbook_by_id, profiles


def validate_queues(candidates, reserves, audit):
    if len(candidates) != audit['produced'] or len(candidates) != 4000 or len(reserves) != 529 or audit['waitingReserve'] != 529:
        raise ValueError('Primary/reserve counts differ from frozen input audit')
    if dict(Counter(r['priorityBucket'] for r in candidates)) != audit['quotas']:
        raise ValueError('Priority quotas differ from audit')
    ids, names = set(), set()
    for row in candidates + reserves:
        sid, name = row['candidateID'], normalize(row['scientificNameInput'])
        if not sid or not name or sid in ids or name in names:
            raise ValueError(f'Duplicate/empty candidate ID or input name: {sid}')
        ids.add(sid); names.add(name)
        if row['reviewStatus'] != 'draft' or row['publicationEligible'] != 'false' or row['regionAssignment'] != 'UNASSIGNED_GLOBAL':
            raise ValueError(f'Input must be unapproved global staging: {sid}')
        if row['wormsAphiaID'] or row['acceptedNameAfterWoRMS']:
            raise ValueError(f'Historic queue cannot assert verified taxonomy: {sid}')
    checks = {'workbookUUIDReused': sum(bool(r['existingWorkbookCreatureID']) for r in candidates),
              'candidatesRequireSchemaReview': sum(r['requiresCategorySchemaReview'] == 'yes' for r in candidates),
              'missingCommonNames': sum(not r['commonNameInput'] for r in candidates)}
    for key, count in checks.items():
        if audit[key] != count:
            raise ValueError(f'Audit {key} mismatch')


def identity_link(row, by_name, by_id, workbook_by_id):
    name = normalize(row['scientificNameInput'])
    existing = by_name.get(name, set())
    declared = row['existingWorkbookCreatureID']
    if len(existing) > 1:
        return None, 'conflicting_existing_UUIDs'
    if declared:
        source = workbook_by_id.get(declared)
        if not source or name not in by_id.get(declared, set()) or existing != {declared}:
            return None, 'conflicting_workbook_link'
        if row['existingWorkbookSourceID'] != source['source_id'] or row['existingWorkbookSourcePage'] != str(source['source_book_page']):
            return None, 'conflicting_workbook_provenance'
    if existing:
        return next(iter(existing)), 'existing_identity'
    return str(uuid.uuid5(NAMESPACE, row['candidateID'])), 'new_provisional_identity'


def intake(root=ROOT):
    snapshot = InputSnapshot(root)
    candidates = snapshot.csv('Data/GlobalMarine/Expansion4000_CandidateQueue.csv')
    reserves = snapshot.csv('Data/GlobalMarine/Expansion4000_ReserveQueue.csv')
    audit = snapshot.json('Data/GlobalMarine/Expansion4000_Audit.json')
    validate_queues(candidates, reserves, audit)
    sources = {}
    for key, expected in [('reef', audit['snapshotSources'][0]['blobSHA']), ('asfis', audit['snapshotSources'][1]['blobSHA'])]:
        path = f'Data/GlobalMarine/Sources/{key}.csv'
        content = snapshot.content[path]
        actual = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
        if actual != expected:
            raise ValueError(f'Source snapshot changed: {key}')
        sources[key] = {normalize(r['Species' if key == 'reef' else 'species_main']) for r in snapshot.csv(path)}
    by_name, by_id, workbook, profiles = existing_identities(root, snapshot)
    app_ids = {p['id'] for p in profiles}
    links = []
    for row in candidates + reserves:
        sid, status = identity_link(row, by_name, by_id, workbook)
        url = row['primarySourceURL']
        source_key = 'reef' if 'Trophic_Fish_2020' in url else 'asfis' if 'asfis-species-list' in url else None
        lineage = 'exact_snapshot_name' if source_key and normalize(row['scientificNameInput']) in sources[source_key] else 'source_name_not_found' if source_key else 'overview_requires_species_account'
        links.append({'candidateID':row['candidateID'], 'sourceName':row['scientificNameInput'], 'speciesID':sid,
                      'identityStatus':status, 'existingAppRecord':sid in app_ids, 'sourceLineage':lineage,
                      'queue':'primary' if row in candidates else 'reserve'})
    report = {'schemaVersion':1, 'primaryCandidates':len(candidates), 'reserves':len(reserves),
              'bucketCounts':dict(Counter(r['priorityBucket'] for r in candidates)),
              'primaryIdentityCounts':dict(Counter(r['identityStatus'] for r in links[:4000])),
              'primarySourceLineageCounts':dict(Counter(r['sourceLineage'] for r in links[:4000])),
              'categoryReviewRequired':sum(r['requiresCategorySchemaReview']=='yes' for r in candidates),
              'existingAppRecords':len(profiles), 'existingWorkbookRows':len(workbook),
              'unreadableExistingIdentityIDs':sorted(sid for sid,names in by_id.items() if not names),
              'inputSHA256':snapshot.manifest['files'],
              'inputManifest':snapshot.manifest, 'inputFingerprint':fingerprint(snapshot.manifest),
              'policy':'Provisional IDs are stable candidate IDs, not accepted taxonomy. No application writes or publication promotion.'}
    return candidates, reserves, links, report, by_name


if __name__ == '__main__':
    _, _, links, report, _ = intake()
    atomic_json(ROOT / 'Reports/GlobalMarine4000Intake.json', report)
    write_csv(DATA / 'IntakeCrosswalk.csv', links, list(links[0]))
    print(json.dumps({k:v for k,v in report.items() if k != 'inputSHA256'}, indent=2))
