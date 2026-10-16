import copy
import json
import unittest
from intake import ROOT
from compare_quality import compare

class ComparisonTests(unittest.TestCase):
    def setUp(self):self.report=json.loads((ROOT/'Reports/TropicalPacificExpansionEvaluation.json').read_text())
    def test_existing_failures_remain_visible_without_new_regression(self):self.assertEqual(compare(self.report,self.report),[])
    def test_lost_recall_and_worse_rank_fail(self):
        after=copy.deepcopy(self.report)
        case=next(c for c in after['groups'][0]['cases'] if c['candidateRecalled'] and c['displayedRank'])
        case['candidateRecalled']=False;case['displayedRank']+=1
        reasons={r[-1] for r in compare(self.report,after)}
        self.assertIn('candidate_recall',reasons);self.assertIn('displayed_rank',reasons)
    def test_missing_case_or_group_is_not_a_pass(self):
        for kind in ('case','group'):
            after=copy.deepcopy(self.report)
            if kind=='case':after['groups'][0]['cases'].pop()
            else:after['groups'].pop()
            with self.assertRaises(ValueError):compare(self.report,after)
    def test_freeze_change_fails_closed(self):
        after=copy.deepcopy(self.report);after['fixtureSHA256']='changed'
        with self.assertRaises(ValueError):compare(self.report,after)

if __name__=='__main__':unittest.main()
