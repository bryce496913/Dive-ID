import contextlib
import io
"""Batch review of the Global pack: seeded samples, manifests, recorded decisions and fail-closed approval.

Records are synthetic; every test works in a temporary directory."""
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import global_batches as G  # noqa: E402
from catalog_review import content_fingerprint  # noqa: E402

ID = "00000000-0000-0000-0000-{:012d}".format


def species(n):
    return {"id": ID(n), "commonName": f"Fish {n:03d}", "scientificName": f"Genus species{n}", "categories": ["fish"],
            "summary": f"Summary {n}.", "distinguishingFeatures": [f"Feature {n}."], "geographicRange": "Pacific Ocean.",
            "dataSources": [{"stableSourceID": f"FishBase:SpecCode:{n}", "sourceName": "FishBase (v26.06)",
                             "sourceURL": f"https://www.fishbase.se/summary/SpeciesSummary.php?ID={n}",
                             "citationReference": "Ref", "reviewedFields": ["summary"]}],
            "review": {"status": "draft", "reviewerNotes": None, "reviewDate": None, "verifiedBy": None}}


class Workspace:
    """A pack of 80 records in batch 1 (5 flagged) and 10 in batch 2."""

    def __init__(self):
        self.temp = tempfile.TemporaryDirectory()
        base = Path(self.temp.name)
        self.pack, self.root, self.pages = base / "Global", base / "Batches", base / "Pages"
        self.pack.mkdir()
        self.records = [species(n) for n in range(1, 91)]
        self.risk = {r["id"]: {"batch": 1 if n <= 80 else 2, "score": 20 if n <= 5 else 0,
                               "flags": ["no_english_common_name"] if n <= 5 else []} for n, r in enumerate(self.records, 1)}
        self.risk_path = base / "RiskReport.json"
        self.risk_path.write_text(json.dumps({"records": self.risk}))
        (self.pack / "PackManifest.json").write_text(json.dumps({"id": "global", "packVersion": 2}))
        self.save()

    def save(self):
        (self.pack / "Creatures.json").write_text(json.dumps(self.records))

    def prepare(self, batch=1, seed=None, force_new=False):
        return G.prepare(batch, seed, force_new, root=self.root, pages=self.pages, pack=self.pack, risk_path=self.risk_path)

    def record(self, manifest, outcome="approve", text="Approved batch 1.", **kwargs):
        return G.record(manifest["manifestSHA256"], "Bryce", text, outcome, "2026-10-22", root=self.root, pack=self.pack, commit="abc", **kwargs)

    def approved(self):
        return G.approved_reviews(self.records, self.root)

    def ids(self, manifest, selection):
        return [e["speciesID"] for e in manifest["records"] if e["selection"] == selection]


class NamedBatchTests(unittest.TestCase):
    """A named batch of explicit IDs, e.g. the 8 Caribbean records rebuilt from FishBase."""
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.temp.cleanup)
        self.members = [r["id"] for r in self.w.records[80:88]]

    def prepare(self, **kwargs):
        return G.prepare(None, None, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path,
                         members=self.members, name="caribbean", **kwargs)

    def test_named_batch_shows_every_record_and_its_approval_covers_exactly_them(self):
        manifest, path, page = self.prepare()
        self.assertEqual(manifest["batchID"], "batch-caribbean")
        self.assertEqual(sorted(e["speciesID"] for e in manifest["records"]), sorted(self.members))
        self.assertEqual(manifest["counts"]["unread"], 0, "a small batch puts every record on the page")
        self.assertTrue(path.exists() and page.exists())
        self.w.record(manifest, text="Approve the 8 Caribbean records.")
        reviews, report = self.w.approved()
        self.assertEqual(set(reviews), set(self.members))
        self.assertTrue(all(r["reviewMethod"] == "individually-reviewed" for r in reviews.values()))
        self.assertEqual(report["approvedBatches"], ["batch-caribbean g1"])

    def test_named_batch_assesses_records_absent_from_the_risk_report_with_the_current_validators(self):
        # The carried Caribbean records are not built from FishBase, so they have no risk entry.
        for member in self.members:
            del self.w.risk[member]
        self.w.risk_path.write_text(json.dumps({"records": self.w.risk}))
        for record in self.w.records[80:87]:
            record["regions"] = ["caribbean"]
        self.w.save()
        manifest, _, _ = self.prepare()
        self.assertEqual(manifest["counts"], {"flagged": 1, "sampled": len(self.members) - 1, "unread": 0})
        flagged = [e for e in manifest["records"] if e["selection"] == "flagged"]
        self.assertEqual([(e["speciesID"], e["flags"], e["riskScore"]) for e in flagged], [(ID(88), ["distribution_missing"], 15)])

    def test_named_batch_rejects_bad_names_unknown_ids_and_rereview(self):
        for name in (None, "", "7", "07-rereview", "Caribbean", "a_b"):
            with self.assertRaises(G.ReviewError):
                G.prepare(None, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path,
                          members=self.members, name=name)
        with self.assertRaises(G.ReviewError):
            G.prepare(None, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path,
                      members=["not-in-pack"], name="caribbean")
        with self.assertRaises(G.ReviewError):
            self.prepare(rereview=True)
        with self.assertRaises(G.ReviewError):
            G.prepare(None, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path)

    def test_cli_requires_name_and_ids_together(self):
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            self.assertNotEqual(G.main(["prepare", "--name", "caribbean"]), 0)


class PartitionTests(unittest.TestCase):
    """Numbered batches cover every pack record exactly once."""
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.temp.cleanup)

    def test_records_absent_from_the_risk_report_join_the_last_batch_and_risk_only_records_are_skipped(self):
        carried = [species(n) for n in range(91, 99)]
        self.w.records += carried
        self.w.risk[ID(500)] = {"batch": 2, "score": 30, "flags": ["missing_required:geographicRange"]}  # left out of the pack
        self.w.risk_path.write_text(json.dumps({"records": self.w.risk}))
        self.w.save()
        numbers = G.batch_assignments(self.w.records, self.w.risk)
        self.assertEqual(set(numbers), {r["id"] for r in self.w.records})
        self.assertTrue(all(numbers[r["id"]] == 2 for r in carried))
        first, second = self.w.prepare(1)[0], self.w.prepare(2)[0]
        covered = [e["speciesID"] for m in (first, second) for e in m["records"]]
        self.assertEqual(sorted(covered), sorted(r["id"] for r in self.w.records), "every record exactly once")
        self.assertEqual(len(second["records"]), 18)
        with self.assertRaises(G.ReviewError):
            self.w.prepare(3)

    def test_the_real_pack_is_covered_exactly_once_with_the_caribbean_records_in_the_last_batch(self):
        records = json.loads((G.PACK / "Creatures.json").read_text())
        risk = json.loads(G.RISK_REPORT.read_text())["records"]
        caribbean = {r["id"] for r in json.loads((G.REPO / "DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json").read_text())}
        numbers = G.batch_assignments(records, risk)
        self.assertEqual(set(numbers), {r["id"] for r in records})
        last = max(numbers.values())
        self.assertEqual({numbers[i] for i in caribbean}, {last})
        self.assertEqual(sorted(set(numbers.values())), list(range(1, last + 1)), "no gap in the numbering")
        assessed = G.record_risk(records, risk)
        self.assertTrue(all(assessed[i] == risk[i] for i in numbers if i in risk), "FishBase records keep the build's flags")

    def test_the_current_manifests_supersede_the_earlier_batch_01_reviews(self):
        manifests = G.load_manifests(G.BATCHES)
        current = [m for _, m in manifests.values() if not G.superseded_by(manifests, m)]
        numbered = [m for m in current if G.re.fullmatch(r"batch-\d+", m["batchID"])]
        if not any(m["batchID"] == "batch-01" and m["generation"] > 1 for m in numbered):
            self.skipTest("the current-content batches are not prepared")
        records = json.loads((G.PACK / "Creatures.json").read_text())
        covered = [e["speciesID"] for m in numbered for e in m["records"]]
        self.assertEqual(sorted(covered), sorted(r["id"] for r in records), "the current batches cover the pack exactly once")
        self.assertEqual([m["batchID"] for m in current if m not in numbered], [], "no earlier re-review batch stays current")
        with tempfile.TemporaryDirectory() as temp:
            copy = Path(temp) / "Batches"  # a copy, so a missed refusal never writes a decision
            shutil.copytree(G.BATCHES, copy)
            for key, (_, manifest) in manifests.items():
                if manifest not in current:
                    with self.assertRaisesRegex(G.ReviewError, "superseded|already recorded"):
                        G.record(key, "Bryce", "test only", "approve", "2026-10-23", root=copy, pack=G.PACK, commit="x")


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.temp.cleanup)

    def test_seed_reproduces_the_sample_and_the_manifest_hash(self):
        first = G.build_manifest(self.w.records, self.w.risk, 1, 1234, 1, {"id": "global", "packVersion": 2})
        again = G.build_manifest(self.w.records, self.w.risk, 1, 1234, 1, {"id": "global", "packVersion": 2})
        other = G.build_manifest(self.w.records, self.w.risk, 1, 1235, 1, {"id": "global", "packVersion": 2})
        self.assertEqual(first, again)
        self.assertNotEqual(self.w.ids(first, "sampled"), self.w.ids(other, "sampled"))
        self.assertEqual(first["counts"], {"flagged": 5, "sampled": 30, "unread": 45})
        self.assertEqual(first["manifestSHA256"], G.manifest_hash(first))

    def test_manifest_lists_every_record_with_its_fingerprint_and_selection(self):
        manifest, manifest_path, page_path = self.w.prepare(seed=7)
        self.assertEqual(json.loads(manifest_path.read_text()), manifest)
        self.assertEqual(len(manifest["records"]), 80)
        by_id = {r["id"]: r for r in self.w.records}
        for entry in manifest["records"]:
            self.assertEqual(entry["reviewedContentFingerprint"], content_fingerprint(by_id[entry["speciesID"]]))
        self.assertEqual(sorted(self.w.ids(manifest, "flagged")), [ID(n) for n in range(1, 6)])
        self.assertTrue(set(self.w.ids(manifest, "sampled")).isdisjoint(self.w.ids(manifest, "flagged")))
        self.assertEqual(manifest["seed"], 7)

    def test_review_page_shows_flagged_by_risk_then_the_sample_with_fields_and_source_links(self):
        self.w.risk[ID(3)]["score"] = 45
        self.w.risk_path.write_text(json.dumps({"records": self.w.risk}))
        manifest, _, page_path = self.w.prepare(seed=7)
        page = page_path.read_text()
        self.assertIn(manifest["manifestSHA256"], page)
        flagged_section, sample_section = page.split("Random sample of unflagged records")
        self.assertLess(flagged_section.index(ID(3)), flagged_section.index(ID(1)), "highest risk first")
        self.assertIn("no_english_common_name", flagged_section)
        for species_id in self.w.ids(manifest, "sampled"):
            self.assertIn(f"id='{species_id}'", sample_section.split("Not shown")[0])
        self.assertIn("https://www.fishbase.se/summary/SpeciesSummary.php?ID=1", page)
        self.assertIn("Summary 1.", page)
        self.assertNotIn(f"id='{self.w.ids(manifest, 'unread')[0]}'", page, "unread records are not presented as read")

    def test_page_rerenders_the_same_sample_and_marks_changed_content(self):
        manifest, _, page_path = self.w.prepare(seed=7)
        original = page_path.read_text()
        self.assertEqual(G.render_page(manifest["manifestSHA256"], root=self.w.root, pages=self.w.pages, pack=self.w.pack), page_path)
        self.assertEqual(page_path.read_text(), original)
        sampled = self.w.ids(manifest, "sampled")[0]
        next(r for r in self.w.records if r["id"] == sampled)["summary"] = "Edited."
        self.w.save()
        G.render_page(manifest["manifestSHA256"], root=self.w.root, pages=self.w.pages, pack=self.w.pack)
        self.assertIn("Content changed after this manifest was generated", page_path.read_text())
        self.assertNotIn("Edited.", page_path.read_text())

    def test_a_tampered_manifest_is_refused(self):
        manifest, manifest_path, _ = self.w.prepare(seed=7)
        tampered = json.loads(manifest_path.read_text())
        tampered["records"][0]["selection"] = "sampled"
        manifest_path.write_text(json.dumps(tampered))
        with self.assertRaises(G.ReviewError):
            self.w.record(manifest)


class RecordTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.temp.cleanup)
        self.manifest = self.w.prepare(seed=7)[0]

    def test_full_approval_marks_read_records_individually_reviewed_and_the_rest_sample_approved(self):
        path, overlay = self.w.record(self.manifest, text="Approved, batch 1")
        self.assertEqual(path.name, "BryceReview2026-10-22-batch-01-g1.json")
        self.assertEqual((overlay["decision"], overlay["verbatimDecision"], overlay["batchManifestSHA256"]),
                         ("approved", "Approved, batch 1", self.manifest["manifestSHA256"]))
        for key in ("schemaVersion", "reviewerIdentity", "reviewDate", "datePrecision", "provenance", "reviewReference", "reviewedCommit"):
            self.assertIn(key, overlay)
        methods = {r["speciesID"]: r["reviewMethod"] for r in overlay["records"]}
        self.assertEqual(len(methods), 80)
        for species_id in self.w.ids(self.manifest, "flagged") + self.w.ids(self.manifest, "sampled"):
            self.assertEqual(methods[species_id], "individually-reviewed")
        for species_id in self.w.ids(self.manifest, "unread"):
            self.assertEqual(methods[species_id], "sample-approved")
        reviews, report = self.w.approved()
        self.assertEqual(len(reviews), 80)
        self.assertEqual(report["approvedBatches"], ["batch-01 g1"])
        unread = reviews[self.w.ids(self.manifest, "unread")[0]]
        self.assertEqual((unread["status"], unread["verifiedBy"], unread["reviewDate"], unread["reviewMethod"]),
                         ("verified", "Bryce", "2026-10-22T00:00:00Z", "sample-approved"))
        self.assertIn("not individually read", unread["reviewerNotes"])
        self.assertIn('"Approved, batch 1"', unread["reviewerNotes"])

    def test_partial_approval_holds_excluded_and_rejected_records(self):
        flagged, unread = self.w.ids(self.manifest, "flagged"), self.w.ids(self.manifest, "unread")
        _, overlay = self.w.record(self.manifest, excludes=[f"{unread[0]}=deferred to the next batch"],
                                   rejects=[f"{flagged[0]}=wrong animal group"])
        self.assertEqual(overlay["decision"], "approved")
        held = {h["speciesID"]: (h["outcome"], h["note"]) for h in overlay["heldRecords"]}
        self.assertEqual(held, {unread[0]: ("excluded", "deferred to the next batch"), flagged[0]: ("rejected", "wrong animal group")})
        reviews, _ = self.w.approved()
        self.assertEqual(len(reviews), 78)
        self.assertNotIn(unread[0], reviews)
        self.assertNotIn(flagged[0], reviews)

    def test_an_error_in_a_sampled_record_rejects_the_whole_batch(self):
        sampled = self.w.ids(self.manifest, "sampled")[0]
        _, overlay = self.w.record(self.manifest, text="Sample record has the wrong depth.",
                                   rejects=[f"{sampled}=depth range is wrong"])
        self.assertEqual(overlay["decision"], "rejected")
        self.assertEqual(overlay["records"], [])
        self.assertEqual(overlay["rejection"]["sampleErrors"], [{"speciesID": sampled, "note": "depth range is wrong"}])
        reviews, report = self.w.approved()
        self.assertEqual((reviews, report["rejectedBatches"]), ({}, ["batch-01 g1"]))

    def test_explicit_rejection_needs_a_reason(self):
        with self.assertRaises(G.ReviewError):
            self.w.record(self.manifest, outcome="reject", text="No.")
        _, overlay = self.w.record(self.manifest, outcome="reject", text="No.", reason="summaries read badly")
        self.assertEqual((overlay["decision"], overlay["rejection"]["reason"]), ("rejected", "summaries read badly"))

    def test_after_rejection_the_batch_is_regenerated_with_a_new_seed(self):
        sampled = self.w.ids(self.manifest, "sampled")[0]
        self.w.record(self.manifest, rejects=[f"{sampled}=wrong"])
        with self.assertRaises(G.ReviewError):
            self.w.prepare(seed=7)
        regenerated = self.w.prepare()[0]
        self.assertEqual(regenerated["generation"], 2)
        self.assertNotEqual(regenerated["seed"], 7)
        with self.assertRaises(G.ReviewError):
            self.w.record(self.manifest, text="Approved after all.")  # one decision per manifest
        self.w.record(regenerated)
        self.assertEqual(len(self.w.approved()[0]), 80)

    def test_a_decision_needs_text_reviewer_and_a_known_current_manifest(self):
        with self.assertRaises(G.ReviewError):
            self.w.record(self.manifest, text="   ")
        with self.assertRaises(G.ReviewError):
            G.record("0" * 64, "Bryce", "Approved", "approve", root=self.w.root, pack=self.w.pack)
        with self.assertRaises(G.ReviewError):
            G.record(self.manifest["manifestSHA256"], "", "Approved", "approve", root=self.w.root, pack=self.w.pack)
        with self.assertRaises(G.ReviewError):
            self.w.record(self.manifest, excludes=[f"{ID(85)}=other batch"])
        undecided = self.w.prepare(force_new=True)[0]
        with self.assertRaises(G.ReviewError):
            self.w.record(self.manifest)  # superseded by generation 2
        self.assertEqual(self.w.approved()[1]["pendingBatches"], ["batch-01 g2"])
        self.w.record(undecided)

    def test_a_pending_generation_is_never_replaced_by_accident(self):
        with self.assertRaises(G.ReviewError):
            self.w.prepare()


class FailClosedTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.temp.cleanup)
        self.manifest = self.w.prepare(seed=7)[0]

    def test_content_changed_after_the_manifest_is_not_approved(self):
        unread = self.w.ids(self.manifest, "unread")
        changed = next(r for r in self.w.records if r["id"] == unread[0])
        changed["summary"] = "Edited after the manifest was generated."
        self.w.save()
        _, overlay = self.w.record(self.manifest)
        self.assertEqual([(h["speciesID"], h["outcome"]) for h in overlay["heldRecords"]], [(unread[0], "stale")])
        reviews, _ = self.w.approved()
        self.assertNotIn(unread[0], reviews)
        self.assertEqual(len(reviews), 79)

    def test_content_changed_after_approval_drops_that_record_only(self):
        self.w.record(self.manifest)
        target = self.w.ids(self.manifest, "sampled")[0]
        next(r for r in self.w.records if r["id"] == target)["colors"] = ["red"]
        reviews, report = self.w.approved()
        self.assertNotIn(target, reviews)
        self.assertEqual(report["staleRecords"], [target])
        self.assertEqual(len(reviews), 79)

    def test_review_fields_outside_the_fingerprint_do_not_break_it(self):
        self.w.record(self.manifest)
        for record in self.w.records:
            record["review"] = {"status": "verified"}
        self.assertEqual(len(self.w.approved()[0]), 80)

    def test_an_overlay_edited_to_a_different_fingerprint_approves_nothing_for_that_record(self):
        path, overlay = self.w.record(self.manifest)
        overlay["records"][0]["reviewedContentFingerprint"] = "sha256:" + "0" * 64
        path.write_text(json.dumps(overlay))
        reviews, report = self.w.approved()
        self.assertNotIn(overlay["records"][0]["speciesID"], reviews)
        self.assertIn(overlay["records"][0]["speciesID"], report["staleRecords"])

    def test_approved_review_validates_on_a_real_global_record_and_method_needs_verified(self):
        import catalogue_validation
        self.w.record(self.manifest)
        review = self.w.approved()[0][self.w.records[0]["id"]]
        real = json.loads((G.PACK / "Creatures.json").read_text())[0]
        catalogue_validation.validate_catalogue([dict(real, review=review)])
        with self.assertRaises(catalogue_validation.CatalogueValidationError):
            catalogue_validation.validate_catalogue([dict(real, review=dict(review, status="draft"))])
        with self.assertRaises(catalogue_validation.CatalogueValidationError):
            catalogue_validation.validate_catalogue([dict(real, review=dict(review, reviewMethod="skimmed"))])


class RereviewTests(unittest.TestCase):
    def setUp(self):
        self.w = Workspace()
        self.addCleanup(self.w.temp.cleanup)
        self.manifest = self.w.prepare(seed=7)[0]
        self.w.record(self.manifest)

    def test_rereview_covers_only_changed_records_and_unchanged_ones_keep_their_approval(self):
        changed = [ID(3), ID(40)]
        for r in self.w.records:
            if r["id"] in changed:
                r["summary"] = "Rebuilt with more evidence."
        self.w.save()
        manifest, _, page = G.prepare(1, None, False, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path, rereview=True)
        self.assertEqual((manifest["batchID"], manifest["generation"]), ("batch-01-rereview", 1))
        self.assertEqual(sorted(e["speciesID"] for e in manifest["records"]), changed)
        self.assertEqual(manifest["rereviewOf"], {"batchID": "batch-01", "generation": 1, "manifestSHA256": self.manifest["manifestSHA256"]})
        self.assertIn("Re-review.", page.read_text())
        reviews, report = self.w.approved()
        self.assertEqual(len(reviews), 78, "the 78 unchanged records keep their approval")
        self.assertEqual(sorted(report["staleRecords"]), changed)
        self.assertEqual(report["pendingBatches"], ["batch-01-rereview g1"])
        G.record(manifest["manifestSHA256"], "Bryce", "Approved the re-review.", "approve", "2026-10-23", root=self.w.root, pack=self.w.pack, commit="x")
        self.assertEqual(len(self.w.approved()[0]), 80)

    def test_a_new_generation_of_the_batch_supersedes_its_rereview(self):
        for r in self.w.records:
            if r["id"] in (ID(3), ID(40)):
                r["summary"] = "Rebuilt with more evidence."
        self.w.save()
        rereview = G.prepare(1, None, False, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path, rereview=True)[0]
        fresh = self.w.prepare(force_new=True)[0]
        with self.assertRaisesRegex(G.ReviewError, "superseded by generation 2 of batch-01"):
            G.record(rereview["manifestSHA256"], "Bryce", "Approved the re-review.", "approve", "2026-10-23", root=self.w.root, pack=self.w.pack, commit="x")
        reviews, report = self.w.approved()
        self.assertEqual((reviews, report["supersededBatches"], report["pendingBatches"]), ({}, ["batch-01-rereview g1"], ["batch-01 g2"]))
        self.w.record(fresh)
        self.assertEqual(len(self.w.approved()[0]), 80)

    def test_an_approved_rereview_stops_counting_once_its_batch_has_a_new_generation(self):
        for r in self.w.records:
            if r["id"] in (ID(3), ID(40)):
                r["summary"] = "Rebuilt with more evidence."
        self.w.save()
        rereview = G.prepare(1, None, False, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path, rereview=True)[0]
        G.record(rereview["manifestSHA256"], "Bryce", "Approved the re-review.", "approve", "2026-10-23", root=self.w.root, pack=self.w.pack, commit="x")
        self.assertEqual(len(self.w.approved()[0]), 80)
        self.w.prepare(force_new=True)
        reviews, report = self.w.approved()
        self.assertEqual(reviews, {}, "only the newest generation of batch-01 counts, and it is undecided")
        self.assertEqual(report["supersededBatches"], ["batch-01-rereview g1"])

    def test_nothing_to_rereview_when_no_approved_record_changed(self):
        with self.assertRaises(G.ReviewError):
            G.prepare(1, None, False, root=self.w.root, pages=self.w.pages, pack=self.w.pack, risk_path=self.w.risk_path, rereview=True)


if __name__ == "__main__":
    unittest.main()
