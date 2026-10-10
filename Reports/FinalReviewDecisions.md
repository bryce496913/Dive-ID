# Final prepared decisions — human approval outstanding

Baseline main: `5c2261921bc463d27daa0585df141aded2c36f27`, after morphology PR #93.
Identified the batch from `releaseBatch: caribbean-two-records-v1` in
Data/CatalogReview/SourceInspectionEvidence.json, then joined species IDs to the
Caribbean overlay and current complete packets. No applicable AGENTS.md found.

| Record | Stable ID | Final content fingerprint |
| --- | --- | --- |
| Atlantic Blue Tang | 00000000-0000-0000-0000-000000000003 | sha256:5fe77e0a07ad5d74e06c8adce87509e0b74afecf2bd767507adc2b35bbfd2bbd |
| Queen Angelfish | fc213eff-6ba6-53ab-b288-f6e654299e68 | sha256:e63d39626d6308de982f643746f5319f1e18dfa1a4ca5bf57530245a521fc63f |

Reopened the original FishBase and Florida Museum pages, including the French
Angelfish comparison account. The generated complete packets now include a
`finalEvidenceAssessment` for every outstanding evidence question, with exact URLs,
sections and reference numbers. No additional biological corrections were justified;
content fingerprints, IDs, original provenance and catalogue bytes remain unchanged.

- Blue Tang: FishBase's recorded 39 cm TL / 2–50 m proposal remains supported by
  references 36453 / 7345. Museum reports 37 cm / 2–40 m. The source pages do not
  explain the disagreement, so it is not declared resolved by choosing a number.
  A human must accept that source precedence with explicit notes or supply better
  evidence and revise/re-review. Museum explicitly supports Bahamas occurrence and
  broad Caribbean abundance; the restricted locality interpretation is supported.
- Queen: FishBase and Museum corroborate the proposed maximum length/depth and
  adult diagnostic traits. Museum's Queen and French Coloration sections support
  the adult comparison. Broad Caribbean occurrence is supported; no island list
  is inferred. Human acceptance of limited juvenile coverage is still required.
  The retained scientific spelling follows the agreeing headings/Taxonomy, rather
  than the conflicting Museum classification-list typo.

Exact citations and complete current content are in CatalogueSourceReviewPass.json;
these packets are regenerated from SourceInspectionEvidence.json. They are source
verification by an automated assistant, not human review decisions.

## Specific decisions still required

For **each** fingerprint above, a real human must supply a decision, reviewer
identity, actual review date and substantive notes covering all stated source
interpretations and limitations. Both existing overlay decisions remain `draft`,
reviewerIdentity/reviewDate null, with unresolved questions retained. The generated
human decision forms are likewise blank. No PR merge, user request to complete
review, or passing test is treated as species publication approval.

Use the existing matching entry in CaribbeanReviewDecisions.json; preserve its
baseline sourceIdentity and corrections, confirm reviewedContentFingerprint, and
apply a genuine decision only after all questions are resolved. Regenerate through
regenerate_caribbean.py, then prepare_source_review_pass.py and prepare_review_batch.py.
The validated overlay rejects stale material changes; changing a fingerprint alone
is not re-review. If the human revises content, bind a new decision to that content.

Decisions applied this pass: **no new human decisions**. Replayed the existing draft
corrections through the overlay. Exact approved ID set, including prior approvals:
`[]`. Caribbean: 8 included, 8 draft, 0 approved. Pacific: 384 included, 384 draft,
0 approved. Both regions remain unavailable under publication access. Positive
Release search remains blocked; there is no real approved batch to demonstrate.

## Verification

The actual publication repository test compares each pack against the complete
current approved ID set, rejects draft IDs, checks full/available counts and listed
status consistency, and rejects zero-approved packs. It automatically includes
future/prior genuine approvals. Dedicated all-draft and synthetic mixed-approval
fixtures remain; mixed status wording and search exclusion assertions remain intact.
Historical saved snapshots are opened while independently confirming their species
is absent from the actual publication repository. No catalogue lookup is needed to
restore the snapshot. Material summary, fin morphology, depth and locality changes
are now all tested to require re-review. No all-draft assumption was added for real
records; existing dynamic real-record tests were retained and strengthened.

Two successive full regenerations produced identical catalogue, manifest and report
bytes. SourceReviewReproducibility.json records the hashes. Xcode is unavailable
locally; portable `.publication` tests are not a hosted Release application run.

Local validation: Swift 6.2.3 full suite **128 tests, 2 skipped (hosted-only and
opt-in trace), zero failures**; Python **19 review, 6 import and 3 evaluation-contract
tests passed**. Frozen development evaluation remains green. No positive publication
search was counted as passed against the empty subset.

[Baseline hosted run 38055496564](https://github.com/bryce496913/Dive-ID/actions/runs/38055496564)
is tied to the baseline SHA above, not this new test/packet commit. Xcode 16.4 Debug
and Release resolved-settings checks passed. Build-for-testing failed:
`OfflineIdentificationPackTests.swift:20: sending 'defaults' risks causing data races`.
Complete unit, packaging and UI targets were consequently skipped. macOS SwiftPM
passed independently. Logs/result bundles were uploaded by the workflow. Hosted
Release application tests and physical-device checks remain unexecuted; neither
resolved settings nor portable publication tests substitute for them.

Optimized portable checks: `swift test -c release` ran four selected tests with zero
failures: actual bundled publication availability/IDs, synthetic mixed publication
counts/status, dedicated all-draft unavailability, and excluded historical snapshot
access. This is Linux SwiftPM Release optimization, not a hosted Xcode Release app.
