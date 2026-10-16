# Expanded catalogue search repair — 2026-10-16

## Reproduction identity

Baseline production tree: main `9657014553a57ba69117ce0c3255bac61db27afd`
(tree `0712d1a11b58f7826c8a159f560d56cbd3c06ab9`); local baseline
`97994aeb5a72471f2f01467581f73f7bf6f8bece` has that identical tree.
The repair is identified by the containing PR's commit and Actions checks.
Production remains BM25 (k1=1.2, b=0.75), 50 candidates, biological ranking,
10 displayed results. The full-pack structured comparator remains mandatory.

Pacific: 1,000 profiles, all draft; Caribbean: 8, including two approved.
No catalogue, source overlay, review decision, engine selection, fixture or
acceptance threshold changes are part of this repair.

- Pacific Creatures.json SHA256: `bd230f0e7aa580afe9e68a08373b3503a776fe3d735a3b866495174f2e281920`.
- Expanded search-document fingerprint: `b58c14b80fc5e8d05f65411c944f478867c130b4d8d954d8e5b13819c04b7f71`.
- Original 384-profile fingerprint: `9cd941bc1e2ef0c22480266c7e23a6234bba139b5a2161ee2f5289528a5f4f8d`.
- Frozen v2 fixture SHA256: `cea70b8ac18076319daf69e36444ba93c7f0897ae84df8238606ae1a297ff21f`.
- Pacific v1 fixture SHA256: `0552a1038be2520483927629befbada141fc30e1dd85413bfd1180688ba5d9e6`.

The pre-expansion comparison removes exactly the 616 expansion UUIDs, preserving
all remaining profiles byte-for-byte. Search-document fingerprints do not identify
tokenizer versions; use the code revision as well.

## Four baseline assertions

Fresh local execution reproduced the [main hosted run](https://github.com/bryce496913/Dive-ID/actions/runs/38828310805).
Hosted job 116740891589 built successfully, then executed 206 unit tests with
three skips and four failures across three tests:

1. `testSourceCorrectionsSurviveRetrievalAndBiologicalRanking`: Fire Dartfish
   displayed 6, historical diagnostic expected exactly 5.
2. `testVersionedDiverDescriptionsThroughProductionIdentificationService`:
   `pacific-v1-fire-dartfish` exceeded its frozen maximum 5.
3. `testVersionedDevelopmentEvaluationThroughApplicationService`:
   `v05-14-paraphrase` failed the production BM25 rank requirement.
4. The same method/case failed its independent full-pack structured comparator.

That run's explicit packaging test and both UI tests passed. The repair preserves
those independent stages. The Fire diagnostic now requires rank **1**, while its
frozen acceptance bound remains **5**. No failed assertion is removed.

## Root causes and correction

### Compound hues were counted as separate independent colors

Fire Dartfish is retrieved second in the expanded pack, so its failure is not a
candidate-boundary problem. Its raw evidence is fish 6 + tail 4 + red 3 + hovering
2 = 15. It has no contradictions. Before expansion, Leopard Grouper's raw 16
plus retrieval relevance ranked just below Fire. Changed corpus statistics raise
Leopard's normalized retrieval contribution enough to overtake Fire. **No newly
added species directly displaces Fire in its top six.** The added corpus changes
the ordering of existing competitors.

Yellownose Slender Anthias, Flame Anthias, Strawberry Grouper, Twospot Anthias and
Leopard Grouper received two full color rewards for the single compound
“orange-red.” Independent color lists do not establish a compound hue. Hyphenated
compound colors now share one color evidence group. Coordinated colors such as
“orange and red” remain separate. Explicit source wording that supports the same
compound hue can supply relational evidence; this is distinct from matching two
unordered list entries. This also preserves useful “blue-green” evidence in the
Bird Wrasse account rather than treating any blue or green animal equivalently.

### Color/marking relationships were discarded

The surgeonfish query yields black, blue, yellow, stripes, compressed, fish and
3 m depth. The record supports fish 6 + stripes 4 + three colors 9 = 19. Its
body shape and lower depth bound are unknown, so neither supplies a reward or
contradiction. Its source transcription explicitly says “black edged blue
stripes,” but retrieval and ranking reduced that to independent words/sets.

Added competitors including Eyestripe Surgeonfish, Flagtail Blanquillo Tilefish,
Goldline Coris, Indo-Pacific Sergeant, Masked Rabbitfish, Orange-faced Angelfish
and Ribbon Sweetlips share broad color/stripe lists. Short generated documents
and repeated list terms help their BM25 scores; each also receives the same raw
19 points even when those colors are not attached to the stripes. The expected
species falls from retrieval 17 to 53 and from structured rank 6 to 15.

The existing vocabulary now canonicalizes explicit adjacent colored markings
(e.g. blue bands/blue-striped/blue stripes) and compound hues on both sides of
retrieval. A relationship contributes one deduplicated BM25 term using the same
IDF/length normalization as other terms. Biological ranking adds one bounded
2-point relationship group when affirmative source prose independently supports
it, the same scale as existing detailed morphology evidence. Multiple aliases,
repeated summary text, or multiple matched relationships cannot multiply that
bonus. Unknown or different relationships cause no new contradiction.

Commas, semicolons and document separators cannot turn unordered trait lists into
relationships. Negated phrases do not add relationships. “Dark” remains a marking
color alias but is excluded from compound hue extraction: “dark blue” does not
assert a black-blue hue. This is a narrow grammar, not unrestricted language
understanding. Existing confidence caps and eligibility thresholds are unchanged;
retrieval relevance still affects ordering rather than user-facing match strength.

## Existing source evidence used

No biological correction or publication approval was inferred. These are existing
traceable transcriptions, not newly human-verified accounts:

- Fire Dartfish `7a662be3-854f-5819-8d32-cb8b1f19a00b`: `SRC-E19DD980`,
  Reef Fish Identification: Tropical Pacific, p.282 (PDF p.283), reddish brown
  rear body and hovering above burrows. The separate existing Fishes of Australia
  fin correction is unchanged and supplies no unobserved fin bonus here.
- Striped Surgeonfish `9353ee92-eaa7-5bcb-b2f8-8b3a0577d5b4`: `SRC-A12D3C83`,
  same book p.48 (PDF p.49), “black edged blue stripes.”
- Bird Wrasse `5af89b7e-ac74-545c-9a78-cd3b0e91101b`: `SRC-2B06E52B`,
  p.209 (PDF p.210), “blue- green head, green body.”
- Leopard Grouper `a9860c43-98af-5c69-919b-117dc9190340`: `SRC-71ACF22B`,
  p.155 (PDF p.156), red-orange spots and tail markings. It is a legitimate
  competitor and is retained, including its explicit compound-hue evidence.

No missing source trait was manufactured to make a case pass. Draft OCR and
stage-specific prose still require review; these changes do not resolve their
underlying source-quality limitations.

## Before/after traces

| Case / catalogue | Before retrieval (BM25) | After retrieval (BM25) | Before displayed | After displayed | Before/after structured rank |
|---|---:|---:|---:|---:|---:|
| Fire / 384 | 1 (15.28) | 1 (15.29) | 5 | 1 | 9 / 2 |
| Fire / 1,000 | 2 (16.88) | 2 (16.86) | 6 | 1 | 9 / 2 |
| Surgeonfish / 384 | 17 (8.38) | 8 (11.41) | 6 | 3 | 6 / 4 |
| Surgeonfish / 1,000 | 53 (6.61) | 14 (10.03) | absent | 3 | 15 / 4 |

Fire remains raw 15, ordering 21.79; surgeonfish becomes raw 21, ordering 27.16.
Both remain eligible with no contradictions. The surgeonfish's new retrieval
term represents blue stripes, rather than a species or fixture identity. Service
normalization retains the resulting ranks; the frozen service-path evaluation
exercises the actual returned order, separately from isolated ranker diagnostics.

`ExpandedCatalogueSearchTraces.json` retains baseline and corrected observations,
source documents, competing candidates, scores, eligibility and ranks. Corrected
traces additionally include per-term BM25 frequencies, IDF and contributions.
`ExpandedCatalogueSearchEvaluation.json` records the complete unchanged evaluation.

## Reproduce validation

From the repository root with Swift installed:

```sh
DIVEID_V05_REPORT=/tmp/evaluation.json DIVEID_EXPANSION_TRACE=/tmp/trace.json swift test --jobs 4
swift test -c release --jobs 4
python3 -m pip install -r Tools/TropicalPacificWorkbook/requirements.txt -r Tools/CatalogImport/requirements.txt
```

Run `python3 -m unittest discover -s Tools/<suite> -p 'test_*.py' -v`
independently for TropicalPacificWorkbook, CatalogImport, CatalogReview,
GlobalMarineImport, SemanticSearch/tests, CI and Evaluation. All seven were
executed here: **120 tests passed** (9/10/25/22/33/9/12).

The unchanged `.github/workflows/ios-tests.yml` provides exact hosted commands:
resolve a simulator, `build-for-testing`, then separately `test-without-building`
for the complete DiveIDTests target, explicit hosted packaging test and complete
DiveIDUITests target. All run after a successful build even if another test stage
fails. Logs, evaluation JSON and xcresult bundles are retained as Actions artifacts.
This Linux environment cannot itself execute Xcode; use the actual PR run's
commit-bound outcomes, not the existence of the workflow, as hosted evidence.

## Frozen evaluation outcomes

| Access / engine | Candidate recall before → after | Top-1 | Top-3 | Top-10 | No-match | Region conflicts | Confidence limits |
|---|---|---|---|---|---|---|---|
| Development / BM25 + biology | 33/34 → 34/34 | 27/34 → 27/34 | 32/34 → 33/34 | 33/34 → 34/34 | 6/6 | 4/4 | 46/46 |
| Development / full-pack comparator | 34/34 → 34/34 | 22/34 → 23/34 | 30/34 → 31/34 | 33/34 → 34/34 | 6/6 | 4/4 | 46/46 |
| Publication / BM25 + biology | 4/4 → 4/4 | 3/4 → 3/4 | 4/4 → 4/4 | 4/4 → 4/4 | 3/3 | 2/2 | 10/10 |

Development has 46 cases and 46 actual engine invocations per engine. Both
ambiguous cases pass. Publication has 10 applicable cases, 36 coverage-blocked
cases and 22 engine invocations per engine (including unavailable-coverage
probes); its one applicable ambiguous case passes. Publication comparator results
also remain unchanged. These are synthetic development regressions already used
for implementation, not independent diver accuracy measurements.

Focused coverage checks compound versus coordinated colors, explicit versus
unordered appearance evidence across multiple synthetic species, aliases,
negation, unknown relations and duplicate source prose. Original positive,
no-match, retrieval-versus-ranking diagnostics and the full-pack comparator are
retained. Hosted completion and complete portable-suite counts must be read from
the PR's actual CI run; local Linux evidence does not substitute for Xcode.
