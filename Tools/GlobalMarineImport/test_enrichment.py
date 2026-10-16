import copy
import json
import unittest
from intake import DATA, read_csv
from enrichment import validate_evidence, summarize_fields, stage, assemble_profile
from worms import payload_hash

class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.rows=[json.loads(line) for line in (DATA/'EnrichmentEvidence.jsonl').read_text().splitlines()]
        self.candidates=read_csv(DATA/'Expansion4000_CandidateQueue.csv')
    def resign(self,row):
        row['evidenceFingerprint']=payload_hash({k:v for k,v in row.items() if k!='evidenceFingerprint'})
    def test_actual_source_packets_retain_conflicts_and_no_publication(self):
        packets,profiles,report=stage(self.candidates,[],self.rows,False)
        self.assertEqual(len(packets),2);self.assertEqual(profiles,[])
        self.assertEqual(packets[0]['conflictingFields'],['depth'])
        self.assertEqual(packets[1]['conflictingFields'],['measurements'])
        self.assertEqual(report['publicationEligibleNewProfiles'],0)
        self.assertEqual(report['details'][0]['documentedRegions'],[])
        self.assertEqual(set(report['details'][1]['documentedRegions']),{'caribbean','tropical-pacific'})
        self.assertFalse(any(r['regionalExportEligible'] for r in report['details']))
    def test_modified_or_duplicate_evidence_rejected(self):
        changed=copy.deepcopy(self.rows);changed[0]['value']='Invented'
        with self.assertRaisesRegex(ValueError,'fingerprint'):validate_evidence(changed,self.candidates)
        with self.assertRaisesRegex(ValueError,'fingerprint'):validate_evidence(self.rows+[self.rows[0]],self.candidates)
    def test_wrong_species_and_fake_review_rejected(self):
        for key,value in [('sourceScientificName','Wrong species'),('humanReviewer','Automated approval')]:
            rows=copy.deepcopy(self.rows);rows[0][key]=value;self.resign(rows[0])
            with self.assertRaises(ValueError):validate_evidence(rows,self.candidates)
    def test_unknown_measurement_type_cannot_be_supported(self):
        rows=copy.deepcopy(self.rows)
        row=next(r for r in rows if r['field']=='measurements');row['value']['type']='unspecified';self.resign(row)
        with self.assertRaisesRegex(ValueError,'measurement type'):validate_evidence(rows,self.candidates)
    def test_conflicting_supported_values_are_not_silently_overwritten(self):
        rows=copy.deepcopy(self.rows[:1]);other=copy.deepcopy(rows[0]);other['value']='Other name';rows.append(other)
        fields,conflicts=summarize_fields(rows)
        self.assertNotIn('commonName',fields);self.assertIn('commonName',conflicts)
    def test_global_source_without_localities_cannot_assign_region(self):
        rows=copy.deepcopy(self.rows);row=next(r for r in rows if r['field'].startswith('region.'))
        row['value']['localities']=[];self.resign(row)
        with self.assertRaisesRegex(ValueError,'localities'):validate_evidence(rows,self.candidates)
    def test_unsupported_category_stays_pending_not_coerced_to_fish(self):
        rows=copy.deepcopy(self.rows);row=next(r for r in rows if r['field']=='categories')
        row['value']=['echinoderm'];self.resign(row)
        packets,profiles,_=stage(self.candidates,[],rows,False)
        self.assertIn('category_schema_review',packets[0]['blockingReasons']);self.assertEqual(profiles,[])
    def test_synthetic_complete_packet_assembles_only_a_draft(self):
        candidate=next(c for c in self.candidates if c['candidateID']=='MARINE5K-03673')
        rows=[r for r in self.rows if r['candidateID']==candidate['candidateID'] and r['evidenceStatus']=='supported']
        # Synthetic taxonomic identity for testing only; never included in real data.
        taxon={'speciesID':'00000000-0000-0000-0000-000000000101','acceptedAphiaID':'101','acceptedScientificName':candidate['scientificNameInput'],'sourceCandidateIDs':candidate['candidateID']}
        _,profiles,report=stage([candidate],[taxon],rows,True)
        self.assertEqual(len(profiles),1)
        self.assertEqual(profiles[0]['review']['status'],'draft')
        self.assertIsNone(profiles[0]['review']['verifiedBy'])
        self.assertIsNone(profiles[0]['maximumSizeCentimeters'])
        self.assertIsNone(profiles[0]['measurements'])
        self.assertEqual(report['publicationEligibleNewProfiles'],0)

    def test_taxonomy_and_region_alone_do_not_complete_profile(self):
        candidate=next(c for c in self.candidates if c['candidateID']=='MARINE5K-03673')
        rows=[r for r in self.rows if r['candidateID']==candidate['candidateID'] and r['field'].startswith('region.')]
        synthetic={'speciesID':'00000000-0000-0000-0000-000000000101','acceptedAphiaID':'101','acceptedScientificName':candidate['scientificNameInput'],'sourceCandidateIDs':candidate['candidateID']}
        packets,profiles,_=stage([candidate],[synthetic],rows,True)
        self.assertEqual(profiles,[]);self.assertIn('missing_identification_evidence',packets[0]['blockingReasons'])

if __name__=='__main__':unittest.main()
