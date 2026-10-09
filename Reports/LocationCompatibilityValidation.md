# Location compatibility correction

Baseline: main `48ff1889c594d5e675969c6a4e4997236d7bfd9b` (PR #87), tree `56b219b41ec372efb3d77d1ab29a221bfc643f35`. Started from clean local `codex/v05-device-candidate` with that exact tree; work branch `codex/location-compatibility`. No applicable AGENTS.md files found in repository or workspace ancestors.

## Diagnosis and correction

The parser normalized text and then singularized individual tokens before intersecting them with the controlled region vocabulary. This lost multiword names and Bahamas. Philippines, Indonesia, Australia and Tropical Pacific were present in the Pacific PackManifest's regionAliases but absent from the recognition vocabulary. The resolver discarded aliases outside that vocabulary too. The service already converts conflicting pack compatibility into `regionMismatch`; its behavior did not need changing.

Location recognition now runs on original text independently of biological token singularization. It folds case/diacritics, splits punctuation, matches whole token sequences, and consumes longest phrases first (Western Atlantic and Indo-Pacific do not independently emit their shorter components). Curaçao and Curacao canonicalize to curacao. The four existing Pacific manifest aliases join the recognition set and geographic hierarchy. No catalogue record, provenance, ranking weight, retrieval limit, or evaluation input changed.

Unknown and incomplete names (including ambiguous bare Virgin Islands) stay unspecified. Substrings such as Indianapolis do not match Indian. Multiple recognized locations containing both compatible and incompatible clues stay unspecified rather than choosing one with unsupported certainty. This is bounded alias recognition, not a general geographic or negation parser; unlisted place names remain unknown.

| Case (both engines) | Normalized text / old location token | Before | After | Service outcome |
| --- | --- | --- | --- | --- |
| v05-region-2 | `brown leaflike fish in the philippines.` / `philippine` | no recognized region; unspecified | philippines; conflicting with Caribbean | empty success → regionMismatch |
| v05-region-3 | `blue fish with a crown spot on a reef in the bahamas.` / `bahama` | no recognized region; unspecified | bahamas; conflicting with Pacific | ten displayed results → regionMismatch, zero displayed |
| v05-region-1 | Fiji | fiji; conflicting | unchanged | regionMismatch |
| v05-region-4 | Caribbean | caribbean; conflicting | unchanged | regionMismatch |

New recognition uses `philippines` and `bahamas` before singularization; ordinary biological tokens and normalized text remain unchanged. Retrieval/ranking still run through each existing engine, and the service suppresses wrong-pack output using the corrected compatibility. The paired report records retrieval, diagnostics, displayed IDs and outcomes; the only changed evaluation rows are region-2 and region-3.

## Validation

Swift 6.2.3, Linux x86_64, Debug. Baseline frozen v2 evaluation: 30 assertion failures. Complete post-change SwiftPM suite: 113 tests, one platform skip, 24 assertion failures, all in the existing v0.5 evaluation method. Five focused location tests pass, including every actual manifest alias, both pack directions, punctuation/case/diacritics, phrase boundaries, ambiguous alternatives, unknowns and service-level rejection. Existing complete Pacific positive/no-match fixture, Caribbean production quality gates, benchmark, search architecture, persistence and lifecycle suites pass. Python frozen evaluation contract suite: 3/3 pass. `git diff --check` passes.

Both development engines execute all 46 cases against 8 Caribbean + 384 Pacific profiles. Regional conflicts improve from 2/4 to 4/4. Production candidate recall remains 33/34; top-1/3/10 remain 22/28/30 of 34. Structured recall remains 34/34; top-1/3/10 remain 16/21/24 of 34. No-match remains 4/6 for each engine. Publication has zero eligible records, all 46 cases blocked and zero engine invocations per engine.

Remaining production rank failures: v05-09-paraphrase, v05-10-paraphrase, v05-13-diagnostic, v05-17-paraphrase. Both terrestrial frog cases still violate no-match/confidence requirements in both engines. Structured search additionally misses v05-11-diagnostic/paraphrase, v05-12-diagnostic/paraphrase, v05-15-diagnostic, v05-16-diagnostic and v05-ambiguous-trigger. Full remaining case and aggregate failures are in LocationCompatibilityEvaluation.json. They remain visible for separate fixes.

Reproduce from repository root using Swift 6.2+:

```sh
DIVEID_V05_REPORT=/tmp/location-after.json swift test --jobs 4
python3 -m unittest discover -s Tools/Evaluation -p 'test_*.py' -v
```

The Swift command intentionally exits nonzero for remaining frozen evaluation failures. Local logs: `/tmp/location-before.log`, `/tmp/location-after.log`; full reports: `/tmp/location-before.json`, `/tmp/location-after.json`. Committed LocationCompatibilityEvaluation.json contains paired changed rows, counts, gates and remaining failures. Xcode/iOS SDK and hardware are unavailable: hosted XCTest (including tests excluded by SwiftPM), simulator/UI and device validation were not executed. No claim of those results is made.
