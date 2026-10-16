import copy
import io
import json
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError, URLError
from unittest.mock import Mock
from intake import intake, identity_link, normalize, validate_queues, atomic_json
from worms import Cache, Pending, resolve, payload_hash
from process import canonicalize, load_results

# Synthetic API fixtures ONLY. IDs below are deliberately test data, not real AphiaIDs.
RECORD={'AphiaID':101,'valid_AphiaID':101,'scientificname':'Example marina','valid_name':'Example marina',
        'rank':'Species','status':'accepted','isMarine':1,'isExtinct':0,'genus':'Example','family':'Exampleidae','class':'TestClass','order':'TestOrder','authority':'Synthetic fixture'}

class Response(io.BytesIO):
    status=200
    def __init__(self, value):super().__init__(json.dumps(value).encode())


def resolver_opener(overrides=None):
    overrides=overrides or {}
    def open_(request,timeout):
        url=request.full_url
        kind=next(k for k in ['AphiaRecordsByName','AphiaRecordByAphiaID','AphiaClassificationByAphiaID','AphiaSynonymsByAphiaID'] if k in url)
        values={'AphiaRecordsByName':[RECORD],'AphiaRecordByAphiaID':RECORD,
                'AphiaClassificationByAphiaID':{'AphiaID':101,'child':None},'AphiaSynonymsByAphiaID':[]}
        return Response(overrides.get(kind,values[kind]))
    return open_

class IntakeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.data=intake()
    def test_actual_input_counts_and_lineage(self):
        candidates,reserves,links,report,_=self.data
        self.assertEqual((len(candidates),len(reserves)),(4000,529))
        self.assertEqual(report['primaryIdentityCounts'],{'new_provisional_identity':3693,'existing_identity':307})
        self.assertEqual(report['primarySourceLineageCounts']['exact_snapshot_name'],3994)
        self.assertEqual(len({r['speciesID'] for r in links[:4000]}),4000)
        self.assertFalse(any(r['existingAppRecord'] for r in links[:4000]))
    def test_conflicting_identity_and_provenance_do_not_get_new_uuid(self):
        row={'scientificNameInput':' Example marina ','candidateID':'test','existingWorkbookCreatureID':'existing',
             'existingWorkbookSourceID':'source','existingWorkbookSourcePage':'4'}
        source={'source_id':'source','source_book_page':4}
        args=({'example marina':{'existing'}},{'existing':{'example marina'}},{'existing':source})
        self.assertEqual(identity_link(row,*args),('existing','existing_identity'))
        row['existingWorkbookSourcePage']='5'
        self.assertEqual(identity_link(row,*args),(None,'conflicting_workbook_provenance'))
        row['existingWorkbookCreatureID']='wrong'
        self.assertEqual(identity_link(row,*args),(None,'conflicting_workbook_link'))
    def test_normalization_does_not_correct_spelling(self):
        self.assertEqual(normalize(' Example  MARINA '),'example marina')
        self.assertNotEqual(normalize('Example marna'),normalize('Example marina'))
    def test_duplicate_candidate_rejected(self):
        candidates,reserves,_,_,_=self.data
        from intake import DATA
        audit=json.loads((DATA/'Expansion4000_Audit.json').read_text())
        mutated=copy.deepcopy(candidates);mutated[1]['scientificNameInput']=mutated[0]['scientificNameInput'].upper()
        with self.assertRaisesRegex(ValueError,'Duplicate'):validate_queues(mutated,reserves,audit)

class CacheTests(unittest.TestCase):
    def test_success_roundtrips_offline_with_same_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            live=resolve('Example marina',Cache(d,opener=resolver_opener()))
            never=Mock(side_effect=AssertionError('network prohibited'))
            offline=resolve('Example marina',Cache(d,offline=True,opener=never))
            self.assertEqual(live,offline);self.assertEqual(live['status'],'confirmed');never.assert_not_called()
            self.assertEqual(len(live['evidence']),4)
    def test_rate_limit_retries_and_persists_success(self):
        with tempfile.TemporaryDirectory() as d:
            op=Mock(side_effect=[HTTPError('url',429,'limit',{},None),Response([])])
            sleep=Mock();cache=Cache(d,opener=op,sleep=sleep)
            self.assertEqual(cache.get('test'),[]);self.assertEqual(op.call_count,2);sleep.assert_called_once_with(1)
    def test_server_failure_recovers_on_resume(self):
        with tempfile.TemporaryDirectory() as d:
            op=Mock(side_effect=HTTPError('url',503,'down',{},None))
            with self.assertRaisesRegex(Pending,'server_error'):Cache(d,opener=op,sleep=lambda _:None).get('test')
            self.assertEqual(op.call_count,3)
            with self.assertRaisesRegex(Pending,'server_error'):Cache(d,offline=True).get('test')
            self.assertEqual(Cache(d,opener=lambda *a,**k:Response([])).get('test'),[])
    def test_timeout_network_and_nonretryable_http_remain_distinct(self):
        for error,state,count in [(TimeoutError(),'timeout',3),(URLError('offline'),'network_error',3),(HTTPError('u',403,'no',{},None),'http_error',1)]:
            with tempfile.TemporaryDirectory() as d:
                op=Mock(side_effect=error)
                with self.assertRaisesRegex(Pending,state):Cache(d,opener=op,sleep=lambda _:None).get('test')
                self.assertEqual(op.call_count,count)
    def test_cache_tampering_fails_closed(self):
        with tempfile.TemporaryDirectory() as d:
            Cache(d,opener=lambda *a,**k:Response([])).get('test')
            path=next(Path(d).glob('*.json'));doc=json.loads(path.read_text());doc['payload']=[RECORD];atomic_json(path,doc)
            with self.assertRaisesRegex(Pending,'cache_integrity'):Cache(d,offline=True).get('test')
    def test_dry_run_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            result=resolve('Example marina',Cache(d,dry_run=True))
            self.assertEqual(result['diagnostics'],['cache_missing']);self.assertEqual(list(Path(d).iterdir()),[])

class ResolverTests(unittest.TestCase):
    def check(self, overrides, diagnostic):
        with tempfile.TemporaryDirectory() as d:
            result=resolve('Example marina',Cache(d,opener=resolver_opener(overrides)))
            self.assertEqual(result['status'],'pending');self.assertIn(diagnostic,result['diagnostics']);self.assertIsNone(result['acceptedAphiaID'])
    def test_empty_is_not_transport_failure(self):self.check({'AphiaRecordsByName':[]},'no_exact_match')
    def test_fuzzy_match_not_accepted(self):self.check({'AphiaRecordsByName':[{**RECORD,'scientificname':'Example marna'}]},'nonexact_response_requires_review')
    def test_ambiguous_names_not_accepted(self):self.check({'AphiaRecordsByName':[RECORD,{**RECORD,'valid_AphiaID':202}]},'ambiguous_exact_match')
    def test_shape_change_not_no_match(self):self.check({'AphiaRecordsByName':{'error':'bad request'}},'response_shape_changed')
    def test_unknown_extinction_and_nonmarine_not_accepted(self):
        for changes in [{'isExtinct':None},{'isExtinct':1},{'isMarine':0}]:self.check({'AphiaRecordByAphiaID':{**RECORD,**changes}},'marine_or_extant_not_confirmed')
    def test_non_species_not_accepted(self):self.check({'AphiaRecordsByName':[{**RECORD,'rank':'Genus'}]},'unsupported_rank_or_identifier')
    def test_accepted_target_must_match(self):self.check({'AphiaRecordByAphiaID':{**RECORD,'AphiaID':202,'valid_AphiaID':202}},'accepted_target_mismatch')
    def test_synonyms_require_same_accepted_target(self):self.check({'AphiaSynonymsByAphiaID':[{**RECORD,'AphiaID':99,'valid_AphiaID':202}]},'synonym_shape_or_target_changed')
    def test_exact_synonym_resolves_to_accepted(self):
        source={**RECORD,'AphiaID':99,'status':'unaccepted'}
        with tempfile.TemporaryDirectory() as d:
            r=resolve('Example marina',Cache(d,opener=resolver_opener({'AphiaRecordsByName':[source],'AphiaSynonymsByAphiaID':[source]})))
            self.assertEqual((r['status'],r['sourceAphiaID'],r['acceptedAphiaID']),('confirmed',99,101))

class CanonicalTests(unittest.TestCase):
    def test_accepted_collisions_use_ranked_reserve_and_preserve_crosswalk(self):
        primary=[{'candidateID':'a'},{'candidateID':'b'}];reserve=[{'candidateID':'c'},{'candidateID':'d'}]
        links=[{'candidateID':c,'sourceName':'source '+c,'speciesID':'uuid-'+c,'identityStatus':'new_provisional_identity','existingAppRecord':False,'sourceLineage':'exact_snapshot_name','queue':'primary' if c in 'ab' else 'reserve'} for c in 'abcd']
        results={c:{'status':'confirmed','acceptedAphiaID':aid,'acceptedScientificName':'Taxon '+str(aid)} for c,aid in zip('abcd',[101,101,202,303])}
        cross,canonical,dupes,complete=canonicalize(primary,reserve,links,results,{}, {})
        self.assertEqual(len(canonical),2);self.assertEqual(len(dupes),1)
        self.assertEqual(cross[1]['canonicalSpeciesID'],'uuid-a');self.assertEqual(cross[2]['disposition'],'canonical_draft');self.assertEqual(cross[3]['disposition'],'reserve_not_needed')
    def test_existing_accepted_synonym_reuses_uuid_without_overwrite(self):
        links=[{'candidateID':'a','sourceName':'Old name','speciesID':'new','identityStatus':'new_provisional_identity','existingAppRecord':False,'sourceLineage':'exact_snapshot_name','queue':'primary'}]
        results={'a':{'status':'confirmed','acceptedAphiaID':101,'acceptedScientificName':'Accepted name'}}
        cross,canonical,_,complete=canonicalize([{'candidateID':'a'}],[],links,results,{'accepted name':{'original'}},{})
        self.assertEqual(canonical,[]);self.assertEqual(cross[0]['canonicalSpeciesID'],'original');self.assertFalse(complete)
    def test_stale_checkpoint_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            atomic_json(Path(d)/'primary-01.json',{'inputFingerprint':'old','results':[]})
            with self.assertRaisesRegex(ValueError,'Stale'):load_results(Path(d),'new')

if __name__=='__main__':unittest.main()
