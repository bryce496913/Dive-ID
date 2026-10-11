"""Synthetic schema/runner contracts only; these are not collected observations."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import uuid
import independent_divers as m


def payload():
    return {'schemaVersion':1,'protocolVersion':'independent-v1','datasetVersion':'synthetic-test-v1',
            'observations':[{'observationID':str(uuid.UUID(int=1)), 'description':'Synthetic validator payload only.',
                'collectionDate':'2026-10-10','region':'caribbean','language':'en','consentForEvaluation':True,
                'author':{'kind':'human','participantID':'test-author','attestsOwnUnpromptedWords':True},
                'cohortID':'test-cohort','encounterID':'test-encounter','priorExposure':False,'usedForDevelopment':False,
                'label':{'kind':'identification','acceptableSpeciesIDs':[str(uuid.UUID(int=2))],
                    'verifierID':'test-verifier','verificationDate':'2026-10-10','verifiedWithoutAppResults':True,
                    'notes':'Synthetic schema test, not identity evidence.','evidenceReferences':['test-only-evidence']}}]}

class IndependentContracts(unittest.TestCase):
    def test_authorship_and_identity_are_separate_and_required(self):
        for mutation in [lambda r:r['author'].update(kind='model'),lambda r:r['author'].update(attestsOwnUnpromptedWords=False),
                         lambda r:r['label'].update(verifierID='test-author'),lambda r:r['label'].update(verifiedWithoutAppResults=False),
                         lambda r:r.update(consentForEvaluation=False)]:
            d=payload();mutation(d['observations'][0])
            with self.assertRaises(ValueError):m.validate(d)

    def test_ids_stable_and_multiple_identities_or_unresolved_are_retained(self):
        d=payload();a=m.validate(d)[0];d['datasetVersion']='next';self.assertEqual(a['id'],m.validate(d)[0]['id'])
        d['observations'][0]['label']['acceptableSpeciesIDs'].append(str(uuid.UUID(int=3)))
        self.assertEqual(len(m.validate(d)[0]['expectedSpeciesIDs']),2)
        d['observations'][0]['label']={'kind':'unresolved','acceptableSpeciesIDs':[]}
        self.assertEqual(m.validate(d)[0]['kind'],'unresolved')

    def test_group_split_and_exposure_promote_entire_cohort(self):
        d=payload();r=d['observations'][0]
        for i in range(100):
            r['cohortID']=str(i)
            if m.validate(d)[0]['split']=='holdout':break
        duplicate=copy.deepcopy(r);duplicate['observationID']=str(uuid.UUID(int=4));duplicate['description']='Second synthetic schema payload.'
        duplicate['usedForDevelopment']=True;d['observations'].append(duplicate)
        self.assertEqual({c['split'] for c in m.validate(d)},{'development'})
        duplicate['cohortID']='different'
        with self.assertRaises(ValueError):m.validate(d)

    def test_duplicate_wording_and_bad_labels_rejected(self):
        d=payload();r=copy.deepcopy(d['observations'][0]);r['observationID']=str(uuid.UUID(int=5));d['observations'].append(r)
        with self.assertRaises(ValueError):m.validate(d)
        d=payload();d['observations'][0]['label']['kind']='noMatch'
        with self.assertRaises(ValueError):m.validate(d)

    def test_freeze_keeps_private_provenance_and_rejects_changed_content(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);source=path/'supplied.json';source.write_text(json.dumps(payload()))
            directory=path/'private'
            with patch.object(m,'lock_state',return_value={'candidateSHA':'synthetic'}):
                m.freeze(source,directory)
                self.assertEqual((directory/'provenance.json').stat().st_mode & 0o777,0o600)
                cases=json.loads((directory/'cases.json').read_text());cases['cases'][0]['description']='altered'
                (directory/'cases.json').write_text(json.dumps(cases))
                with self.assertRaisesRegex(ValueError,'Frozen cases changed'):m.evaluate(directory,'must-not-run')

    def test_aggregate_never_emits_case_ids_text_or_empty_success(self):
        rows=[{'id':'secret-id','description':'secret wording','access':'publication','split':'holdout','kind':'identification',
               'blocked':True,'engineInvoked':False,'packSizes':{'caribbean':0},'recalled':False,'rank':None,
               'outcomeCorrect':False,'confidenceOK':True,'serviceError':None,'returnedCount':0}]
        report=m.aggregate(rows);encoded=json.dumps(report)
        self.assertNotIn('secret',encoded)
        group=next(x for x in report['groups'] if x['access']=='publication' and x['split']=='holdout')
        self.assertIsNone(group['metrics']['top1']['rate']);self.assertEqual(group['acceptance'],'insufficient sample')

if __name__=='__main__':unittest.main()
