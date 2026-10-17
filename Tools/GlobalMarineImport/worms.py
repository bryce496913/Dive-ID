"""Exact WoRMS resolver with durable, URL-addressed response snapshots.

Only successful responses are reused online. Errors remain retryable. Offline
replays never perform network I/O or turn a transport failure into a taxon verdict.
"""
import hashlib
import json
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen
from intake import atomic_json, normalize, WORMS_BASE

BASE = WORMS_BASE


class Pending(Exception):
    pass


def payload_hash(payload):
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


class Cache:
    def __init__(self, directory, offline=False, dry_run=False, opener=urlopen, sleep=time.sleep, attempts=3):
        self.directory, self.offline, self.dry_run = Path(directory), offline, dry_run
        self.opener, self.sleep, self.attempts = opener, sleep, attempts
        self.used = {}

    def get(self, endpoint):
        url = BASE + endpoint
        path = self.directory / (hashlib.sha256(url.encode()).hexdigest() + '.json')
        previous = None
        if path.exists():
            previous = json.loads(path.read_text())
            if previous.get('schemaVersion') != 1 or previous.get('url') != url or previous.get('responseSHA256') != payload_hash(previous.get('payload')):
                raise Pending('cache_integrity_error')
            self.used[url] = previous
            if previous.get('state') == 'success':
                return previous['payload']
        if self.offline or self.dry_run:
            raise Pending(previous['state'] if previous else 'cache_missing')
        for attempt in range(self.attempts):
            status, payload, state, retry = None, None, 'network_error', False
            try:
                with self.opener(Request(url, headers={'Accept':'application/json', 'User-Agent':'Dive-ID-research/1.0'}), timeout=20) as response:
                    status = response.status
                    raw = response.read()
                    payload = None if status == 204 else json.loads(raw)
                    state = 'success'
            except HTTPError as error:
                status = error.code
                state = 'rate_limited' if status == 429 else 'server_error' if status >= 500 else 'http_error'
                retry = status == 429 or status >= 500
            except (TimeoutError, socket.timeout):
                state, retry = 'timeout', True
            except URLError:
                state, retry = 'network_error', True
            except (ValueError, UnicodeError):
                state, retry = 'invalid_json', True
            snapshot = {'schemaVersion':1, 'url':url, 'retrievedAt':datetime.now(timezone.utc).isoformat(),
                        'httpStatus':status, 'state':state, 'payload':payload, 'responseSHA256':payload_hash(payload)}
            atomic_json(path, snapshot)  # Persist each completed attempt, even when later work fails.
            self.used[url] = snapshot
            if state == 'success':
                return payload
            if not retry or attempt == self.attempts - 1:
                raise Pending(state)
            self.sleep(min(2 ** attempt, 8))
        raise Pending('network_error')


def integer_id(value):
    return type(value) is int and value > 0


def accepted_record(record):
    if not isinstance(record, dict):
        raise Pending('response_shape_changed')
    if not integer_id(record.get('AphiaID')) or not integer_id(record.get('valid_AphiaID')):
        raise Pending('missing_identifier')
    if record.get('rank') != 'Species':
        raise Pending('unsupported_rank')
    if record.get('isMarine') != 1 or record.get('isExtinct') != 0:
        raise Pending('marine_or_extant_not_confirmed')
    if record.get('status') != 'accepted' or record['AphiaID'] != record['valid_AphiaID']:
        raise Pending('accepted_record_inconsistent')
    if not isinstance(record.get('scientificname'), str) or not record['scientificname'].strip():
        raise Pending('missing_accepted_name')
    if normalize(record.get('valid_name') or '') != normalize(record['scientificname']):
        raise Pending('accepted_name_inconsistent')
    return record


def resolve(name, cache):
    result = {'sourceName':name, 'status':'pending', 'acceptedScientificName':None, 'acceptedAphiaID':None,
              'sourceAphiaID':None, 'authority':None, 'genus':None, 'family':None, 'order':None, 'class':None,
              'rank':None, 'isMarine':None, 'isExtinct':None, 'taxonomicStatus':None,
              'classification':None, 'synonyms':[], 'diagnostics':[], 'evidence':[]}
    cache.used = {}
    start = set()
    try:
        records = cache.get('AphiaRecordsByName/' + quote(name.strip(), safe='') + '?like=false&marine_only=true&extant_only=true')
        if records is None or records == []:
            raise Pending('no_exact_match')
        if not isinstance(records, list) or not all(isinstance(r, dict) for r in records):
            raise Pending('response_shape_changed')
        exact = [r for r in records if normalize(r.get('scientificname') or '') == normalize(name)]
        if not exact:
            raise Pending('nonexact_response_requires_review')
        ids = {r.get('valid_AphiaID') for r in exact if integer_id(r.get('valid_AphiaID'))}
        if len(ids) != 1 or any(not integer_id(r.get('valid_AphiaID')) for r in exact):
            raise Pending('ambiguous_exact_match')
        if any(r.get('rank') != 'Species' or not integer_id(r.get('AphiaID')) for r in exact):
            raise Pending('unsupported_rank_or_identifier')
        if any(r.get('status') not in ('accepted', 'unaccepted') for r in exact):
            raise Pending('unsupported_taxonomic_status')
        source = sorted(exact, key=lambda r:r['AphiaID'])[0]
        accepted = accepted_record(cache.get('AphiaRecordByAphiaID/' + str(next(iter(ids)))))
        if accepted['AphiaID'] not in ids or any(normalize(r.get('valid_name') or '') != normalize(accepted['scientificname']) for r in exact):
            raise Pending('accepted_target_mismatch')
        classification = cache.get('AphiaClassificationByAphiaID/' + str(accepted['AphiaID']))
        node, classification_ids = classification, set()
        while node is not None:
            if not isinstance(node, dict) or not integer_id(node.get('AphiaID')) or node['AphiaID'] in classification_ids:
                raise Pending('classification_shape_changed')
            classification_ids.add(node['AphiaID']); node = node.get('child')
        if accepted['AphiaID'] not in classification_ids:
            raise Pending('classification_missing_target')
        synonyms = []
        for offset in range(1, 5002, 50):
            page = cache.get(f"AphiaSynonymsByAphiaID/{accepted['AphiaID']}?offset={offset}")
            if page is None or page == []:
                break
            if not isinstance(page, list) or not all(isinstance(r, dict) and integer_id(r.get('AphiaID')) and r.get('valid_AphiaID') == accepted['AphiaID'] for r in page):
                raise Pending('synonym_shape_or_target_changed')
            synonyms.extend(page)
            if len(page) < 50:
                break
        else:
            raise Pending('synonym_pagination_limit')
        result.update(status='confirmed', acceptedScientificName=accepted['scientificname'], acceptedAphiaID=accepted['AphiaID'],
                      sourceAphiaID=source['AphiaID'], taxonomicStatus=source['status'], classification=classification,
                      synonyms=sorted(synonyms, key=lambda r:r['AphiaID']))
        for field in ('authority','genus','family','order','class','rank','isMarine','isExtinct'):
            result[field] = accepted.get(field)
    except Pending as error:
        result['diagnostics'].append(str(error))
    result['evidence'] = [{k:snapshot[k] for k in ('url','retrievedAt','responseSHA256','state')} for url,snapshot in sorted(cache.used.items()) if url not in start]
    return result
