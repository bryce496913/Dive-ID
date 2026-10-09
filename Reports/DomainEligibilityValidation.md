# Decisive subject evidence and marine catalogue eligibility

Baseline main: `5f6a9584b76f7d0208954ad340aad22120921f1b`, after merged location PR #88; tree `d7afe0818b777ecddcf88de0cb15a2e08d08b596`. The clean local `codex/location-compatibility` branch matched that tree before creating `codex/domain-contradictions`. No applicable AGENTS.md found in the workspace or repository; ancestor checks from the preceding pass also found none.

## Policy

An affirmative subject assertion identifying a frog, toad or amphibian (including plurals) is decisive evidence outside this marine catalogue. The controlled categories and all 392 bundled records contain no amphibians. This is a category/domain eligibility decision, not a species exception or a negative ranking weight.

The parser records `amphibianSubject` separately from ordinary traits. Recognition uses a deliberately narrow clause-initial subject grammar: optional observation/copular introductions, determiners and bounded descriptive modifiers followed by an amphibian noun. Negation, comparison, uncertainty, questions, compound/body-part descriptions and coordinated marine/amphibian subjects do not establish this contradiction. An amphibian mentioned as another subject's object (e.g. fish eating a frog) does not match. Frogfish and toadfish are distinct whole words. Unknown vocabulary alone never rejects a candidate. Freshwater alone is not a blanket exclusion: habitat wording must not be mistaken for a definitive animal identity.

The shared ranker rejects the entire candidate pool before evidence scoring, exact-name overrides or provisional semantic eligibility when this contradiction is present. Both BM25 and structured engines retain their retrieval diagnostics; nonempty pools become `allCandidatesRejectedByRanker`. The application service returns an ordinary successful empty result. Existing region mismatch still takes precedence when location is incompatible, and catalogue-loading failures still throw before search. No UI error type, biological weight, retrieval limit, catalogue record, or model default changed.

This is not a general language/domain classifier. Unlisted animal nouns, unsupported subject syntax, and clauses with uncertainty remain conservative unknowns. It does not promise to reject every possible terrestrial description or resolve arbitrary discourse and negation scope. Tests cover the supported subject grammar and nearby non-assertions.

## Reproduced eligibility failure

Both failed cases contain the unchanged description `A spotted freshwater frog on sand, about 5 cm long.`:

- `v05-caribbean-terrestrial`
- `v05-tropical-pacific-terrestrial`

Normalization produces `a spotted freshwater frog on sand about 5 cm long.`. Biological parsing recognizes spots, sand, elongated (from long), bottom-swimming (from sand), and size 5 cm. Frog and freshwater supply no marine category. Previously, that absence was merely missing positive category evidence: there was no domain contradiction. The five trait groups passed information eligibility and shared traits cleared the scoring threshold. The existing animal-group contradiction only addressed a fish description versus turtle/ray candidates, so it did not reject these subjects. Neither query has a location, and compatibility stays unspecified.

The new parser retains those same trait fields and records the separate amphibian-subject contradiction; the ranker now makes every candidate ineligible before shared clues are scored.

| Engine / pack | Retrieved before and after | Displayed before → after | Before scores | After outcome |
| --- | ---: | ---: | --- | --- |
| Production BM25 / Caribbean | 3 | 1 → 0 | 0.1667 | no-match |
| Production BM25 / Pacific | 50 | 10 → 0 | 0.1905 each | no-match |
| Structured / Caribbean | 8 | 2 → 0 | 0.1667, 0.0952 | no-match |
| Structured / Pacific | 384 | 10 → 0 | 0.1905 each | no-match |

Scores are relative match scores, not probabilities. Both fixtures require maximum confidence zero because they require no matches. Empty output now meets that requirement. The original simple frog/lily-pad and vague-fish no-match cases remain passing; the Caribbean simple-frog BM25 retrieval miss remains distinguishable from ranker rejection.

## Unchanged evaluation and regression results

Swift 6.2.3 on Linux x86_64, Debug. Baseline v2 evaluation reproduced 24 assertion failures. Full post-change SwiftPM suite executed 119 tests with one platform skip and 16 assertion failures, all in the existing v0.5 evaluation method. All six new parser/eligibility tests pass; they cover decisive exclusions, negation/comparison/object/uncertain wording, all marine category names, nearby valid marine service inputs, exact-name plus synthetic high-cosine retrieval, and separate no-match/region/load outcomes. The semantic signal is a synthetic eligibility test, not real-model validation.

All prior Pacific fixture, Caribbean production quality, location recognition, conservative no-match, benchmark, search architecture, persistence and lifecycle suites pass. Python frozen evaluation contract suite: 3/3 pass. `git diff --check` passes. Evaluation descriptions, IDs, expected species, acceptable ranks, splits, thresholds and frozen files are untouched.

Each development engine executes 46 cases against 8 Caribbean and 384 Pacific records. Only the two terrestrial case rows change:

- Both engines: no-match 4/6 → 6/6; confidence compliance 44/46 → 46/46; region conflicts stay 4/4.
- Production: recall 33/34; top-1/3/10 stay 22/28/30 of 34; ambiguous 2/2.
- Structured: recall 34/34; top-1/3/10 stay 16/21/24 of 34; ambiguous 1/2.
- Publication: zero eligible records, all 46 cases blocked and zero engine calls for each engine. No publication approval was introduced.

Remaining production rank failures: v05-09-paraphrase, v05-10-paraphrase, v05-13-diagnostic, v05-17-paraphrase. Structured also misses v05-11-diagnostic/paraphrase, v05-12-diagnostic/paraphrase, v05-15-diagnostic, v05-16-diagnostic and v05-ambiguous-trigger. Its top-10 aggregate gate remains failing. These remain visible for a separate ranking pass.

The paired `DomainEligibilityEvaluation.json` records exact before/after rows, counts, gates and remaining failures. Existing historical evaluation reports remain untouched.

Reproduce from repository root with Swift 6.2+:

```sh
DIVEID_V05_REPORT=/tmp/domain-after.json swift test --jobs 4
python3 -m unittest discover -s Tools/Evaluation -p 'test_*.py' -v
```

Swift intentionally exits nonzero for the remaining ranking evaluation failures. Session logs: `/tmp/domain-before.log`, `/tmp/domain-after.log`; full reports: `/tmp/domain-before.json`, `/tmp/domain-after.json`. Xcode/iOS SDK and real devices are unavailable. Hosted-only XCTest, simulator/UI and device validation were not executed; no results are claimed for them.
