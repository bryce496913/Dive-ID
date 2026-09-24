import copy, importlib.util, unittest
from pathlib import Path
SPEC=importlib.util.spec_from_file_location("catalog_review", Path(__file__).with_name("catalog_review.py"))
M=importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(M)

def record():
    return {"id":"stable", "commonName":"Name", "scientificName":"Species name", "categories":["fish"],
            "summary":"text", "distinguishingFeatures":["trait"], "dataSources":[{"stableSourceID":"source-1","citationReference":"p. 1"}],
            "review":{"status":"draft"}}
def decision(r):
    return {"schemaVersion":1,"decisions":[{"speciesID":"stable","sourceIdentity":[["source-1","p. 1"]],
      "reviewedContentFingerprint":M.content_fingerprint(r),"corrections":{},"decision":"verified",
      "reviewerIdentity":"Reviewer","reviewDate":"2026-09-24T00:00:00Z","reviewerNotes":"Source checked",
      "unresolvedQuestions":[]}]}
class ReviewTests(unittest.TestCase):
    def test_decision_survives_regeneration(self):
        first=record(); self.assertEqual(M.apply_decisions([first],decision(first))[0]["state"],"applied")
        regenerated=record(); self.assertEqual(M.apply_decisions([regenerated],decision(regenerated))[0]["state"],"applied")
        self.assertEqual(regenerated["review"]["status"],"verified")
    def test_material_change_makes_decision_stale(self):
        original=record(); changed=copy.deepcopy(original); changed["summary"]="changed"
        result=M.apply_decisions([changed],decision(original))[0]
        self.assertEqual(result["state"],"stale"); self.assertEqual(changed["review"]["status"],"draft")
    def test_unresolved_category_blocks_approval(self):
        r=record(); r["categories"]=[]; d=decision(r); d["decisions"][0]["unresolvedQuestions"]=["category needs source page"]
        self.assertEqual(M.apply_decisions([r],d)[0]["state"],"blocked")
        self.assertEqual(r["review"]["status"],"draft")
if __name__ == "__main__": unittest.main()
