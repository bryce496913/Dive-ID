# Hybrid ranking contract

`SpeciesRankingInput` is the boundary between candidate retrieval and biological
ranking. It carries the original description, its structured parse, and candidates
identified by stable catalogue IDs. Each candidate has either an explicit retrieval
signal (source, score kind, raw score, retrieval rank, and source-backed evidence) or
`nil`, which means the structured baseline was used.

## Eligibility and fusion

Structured candidates retain the existing evidence threshold and exact-name path.
A semantic candidate (experimental fallback only; see below) can be admitted
provisionally when its raw cosine is at least `semanticFallbackCosine` (0.55) and the
description contains at least three meaningful non-generic terms. This is intentionally independent of parser vocabulary coverage:
it permits useful paraphrases, while rejecting a high-similarity result for a query
such as “a fish on the reef.” Structured animal-group, size, and habitat conflicts
are still scored after provisional admission and can lower or remove a candidate.

## Photo evidence (2026-10-29, Debug and Internal only)

Fusion rule approved by the owner on 2026-10-29.

A photo search runs a swappable `PhotoRecognizer` on the diver's prepared photo (EXIF
stripped, on the device). It returns ranked species candidates, each with a similarity on
a declared scale and the reference photo it matched, or it abstains. This pass ships only
a deterministic test recognizer (`StubPhotoRecognizer`); there is no real model or
reference index yet, and Release never runs photo recognition.

**Eligibility.**
- Candidates outside the searched pack are dropped. The pack is loaded with the build's
  catalogue access exactly as for a description search, so Release-style publication
  filtering applies to photo candidates too.
- Similarities are normalized to 0–1 before use: cosine with `clamp((s + 1) / 2, 0, 1)`
  (as for semantic retrieval); a 0–1 scale is clamped as is.
- `PhotoMatchingWeights.abstainSimilarity` (provisional 0.5, to be set from development
  data before any evaluation) is the only threshold. The photo **abstains** when the
  recognizer abstains or the best normalized similarity is below it. Otherwise
  candidates below it are dropped.

**Photo only** (no extra text):
- Ordered by normalized similarity, then name and ID; at most ten.
- Every result is `limited` information. Confidence is the normalized similarity capped
  at `LocalRankingWeights.limitedConfidenceCap` (0.64), so a photo alone shows at most
  "Possible match".
- Explanation: "Looks similar to the reference photo."
- When the photo abstains, the screen says there's no confident photo match and offers
  "Describe it instead". Nothing is guessed.

**Photo plus text** ("anything else you noticed"):
- The text goes through the production description search, unchanged (BM25 and
  `LocalSpeciesRanker`, same parse, conflicts and region rules; a region conflict in the
  text is reported as for a description).
- **Tier 1:** species the description search ranked. Ordering score is the description
  ordering score plus `8 × normalized photo similarity` (the same weight as normalized
  retrieval relevance; 0 when the photo didn't propose the species). Confidence, match
  strength, information level and the description's explanation are the description
  search's, unchanged. The photo adds "Looks similar to the reference photo." in front
  of the explanation; it never raises confidence.
- **Tier 2:** species only the photo proposed, ordered after every tier-1 result, scored
  as photo-only results (limited, capped at 0.64). Because the ranker doesn't report
  which species it rejected, a species the text contradicts can still appear here, but
  only below everything the text supports.
- If the photo abstains, the results are the description's alone, with "No confident
  photo match" shown above them.
- Deduplicated by species ID, sorted by tier, ordering score, name and ID, capped at ten.

**Coverage.** Each photo result screen says "Photo matching covers N of M species", where
N is the recognizer's covered species that are in the searched pack and M is the pack's
species count. Species without a reference photo can still be found by describing them.

Description-only searches are unchanged: none of this runs without a photo, and the
golden-ordering fixtures are not regenerated.

## Semantic fallback (2026-10-26)

The Debug-only experimental engine no longer merges semantic candidates into every
search (the 2026-10-23 "semantic complement"). It runs BM25 first and returns any ranked
result unchanged, without loading the model or embedding the query. Only when BM25 ranks
nothing, and the description does not contradict the catalogue's domain (a frog, a land
animal), does it embed the query. It then keeps the ten best semantic candidates at or
above `semanticFallbackCosine`, lets the ranker apply its conflicts, orders them by
cosine, and shows them as `limited` information (confidence capped at 0.64) with the
"catalogue description similarity" clue. The production default (BM25 only) is unchanged.

## Semantic calibration

`LocalRankingWeights.semanticFallbackCosine = 0.55`, frozen on 2026-10-26 from
development cases only: V05Development.v2 and the CaribbeanIdentificationBenchmark
development split (the benchmark holdout was not read). Pack: Global v25, 4,798 records,
real encoder `sentence-transformers/all-MiniLM-L6-v2` at `c9745ed1`.

**Rule:** the cutoff must sit above the best semantic cosine of every development
no-match description, because BM25 abstains on all 20 of them and the fallback would
otherwise answer them. That maximum is **0.5231** (a land-animal description, which the
parser also rejects as a domain contradiction); the next highest no-match cosine is
0.4445. 0.55 is that maximum rounded up to the next 0.05, a 0.027 margin over a
20-case sample. The previous provisional 0.30 floor would have given 13 of the 20
results. The cutoff was not tuned to any identification result.

**Where BM25 abstains (28 of 116 cases):**

| Case | Kind | Top cosine | Top is expected | Expected rank (semantic) | Fallback at 0.55 |
| --- | --- | ---: | --- | ---: | --- |
| realistic-016 | identification | 0.6378 | no | 9 | shown; expected 9th, 9 wrong |
| realistic-011 | identification | 0.6257 | yes | 1 | shown; **expected first**, 9 wrong below it |
| realistic-013 | identification | 0.6022 | yes | 1 | shown; **expected first**, 5 wrong below it |
| realistic-026 | identification | 0.5576 | no | 8 | shown; 2 wrong, expected absent |
| realistic-036 | identification | 0.5250 | no | 5 | abstains |
| realistic-054 | identification | 0.4349 | no | 876 | abstains |
| realistic-045 | identification | 0.3778 | no | 2,558 | abstains |
| realistic-046 | identification | 0.2436 | no | 1,277 | abstains |
| 20 no-match descriptions | noMatch | 0.1023–0.5231 | – | – | all abstain (4 are domain contradictions and never reach the model) |

Of the 7 cases the merge "newly answered", 4 clear the cutoff; the merge showed the
expected species in only one of the 7 (realistic-016, not first), while the fallback
shows it in 3 and first in 2. Other cutoffs above the no-match maximum change only
which identification cases fire: 0.53 adds realistic-036 (expected not first), 0.60
drops realistic-016 and realistic-026.

**Before and after on the same 116 cases:**

| | Merge (cutoff 0.30) | Fallback (cutoff 0.55) |
| --- | ---: | ---: |
| Expected species first | 48 (BM25 alone: 52) | 54 |
| BM25-answered results changed | 12 top results changed | 0 (88 returned unchanged; model not loaded) |
| Cases where semantic ran | 116 | 24 (served 4, nothing above the cutoff 20) |
| Wrong semantic results shown | 147 (143 identification, 3 region conflict, 1 ambiguous) | 25 (identification, in the 4 served cases) |
| Highest confidence on a semantic result | 0.76 | 0.17 |
| No-match descriptions that gained results | 0 | 0 (hard gate in SemanticEndToEndTests) |
| Latency when semantic ran (Mac, Debug SwiftPM) | every search | median 0.57 s, maximum 1.25 s, only in the 24 cases |

These are development results and not independent evidence. Re-measure, and record a new
dated section rather than editing this one, before changing the cutoff or using it on
another pack.

## Animal-group searches (2026-10-23)

Found on device: searching "shark" or "ray" alone listed nothing in Global, although it
holds 150 shark and ray records. A one-word group name was a single clue group, so
information was `insufficient` and every candidate was rejected; "ray" (3 characters)
also could not be submitted under the 5-character minimum.

- Naming a specific animal group (any parser category except `fish`: "shark", "rays",
  "octopus", "crab", "stingray", "manta") is `limited` information, so that group's
  records are listed with confidence capped at 0.64.
- "Fish" alone, "dark fish" and "blue thing" still list nothing, as do the existing
  no-match cases. "Flat thing" lists rays at limited confidence, as it already did
  before this change (body shape "flat" plus category `ray` is two clue groups).
- "stingray" and "manta" now map to the `ray` category.
- Descriptions may be 3 characters or more (was 5), so "ray" and "eel" can be submitted.
- Ordering inside the group is unchanged (evidence score, retrieval relevance,
  occurrence); it does not try to put the most commonly seen species first.

## Group names and appearance variants (2026-10-22)

Changed to fix the Global ranking defects found in the V05 traces. Before, a bare group
alias ("Surgeonfish") gave every record that carried it the +20 exact-name credit and
`sufficient` information. Separately, an appearance variant re-scored colours and
markings the main profile had already matched.

- **Exact names.** The scientific name always counts. A common name or alias does not
  count when it names a group in the searched pack
  (`OfflineIdentificationPack.groupNames`, passed as `SpeciesRankingInput.groupNames`).
  - **A group name is** the last word of any multi-word common name ("surgeonfish"
    from "Twospot surgeonfish"), or an alias carried by more than one record ("coral
    trout").
  - **One-word common names:** these count unless other records' names end in them.
    "Angelfish" (*Holacanthus bermudensis*) and the Tropical Pacific "Shark" (*Rhina
    ancylostoma*) lose exact credit; "Hogfish" keeps it.
  - **What group names still give:** retrieval, and the +1 partial identity term every
    member of the group shares. A group name alone no longer makes a vague description
    identifying or lifts its confidence ceiling.
- **Hyphenated compounds.** A name found only as the tail of a hyphenated compound is
  not named: "red-orange anemonefish" does not name the Orange anemonefish, and
  "blue-lined surgeonfish" does not name the Lined surgeonfish.
- **Variants are alternatives.** Only the best variant counts, as before. It now scores
  only colour groups, markings and body shapes the main profile did not already match,
  so no clue counts twice.
- **Life stage.** A stage or sex named in the description ("juvenile", "male",
  "female", "adult") limits the variants that can count to compatible ones. No stage
  named leaves every variant possible; an unknown stage is never a conflict.
- **Appearance relationships** (`AppearanceEvidenceVocabulary`, used by the query, by
  the species prose and by BM25):
  - Coordinated colours before one marking apply to each colour: "blue and yellow
    stripes" gives blue stripes and yellow stripes.
  - A front-to-rear body contrast is one relationship whichever way it is stated:
    "pale front half and darker rear" and "front half paler than the rear" both give
    "paler front".
- **Vocabulary.**
  - "Maroon" is a red shade.
  - A "-like" word also yields its stem ("birdlike" gives "bird"), in parsing and in
    BM25 terms.

No weight, threshold, floor or species-specific value changed. The golden fixture was
regenerated as `SearchGolden.v2.json`; see Docs/GlobalPackEvaluation.md.

## Location

Location ranks results but never filters them. A region named in the description adds
evidence (“geographic range”) when it matches a species' recorded range. A sighting
outside the recorded range lowers that species' ordering by 3 (owner decision,
2026-10-21, replacing the earlier “no effect” rule). The penalty is applied only after
eligibility is decided, so it never removes a candidate. It is not evidence against the
species: the structured score, confidence and explanations stay exactly as for a
species with no recorded range. A species with no recorded range is neutral.

## Size

A described size is a length. It adds evidence ("compatible size", +3) when it fits
the species' range and counts against it ("described size", −4) when it does not.
The tolerance is unchanged: from half the minimum to 1.5 × the maximum.

- **Range:** the typical observed range is used when present, otherwise the
  recorded maximum and minimum.
- **Maximum only** (2026-10-22, owner-requested size fix): FishBase records give a
  maximum length and no minimum, so a record with only a maximum is now compatible
  from 0 up to 1.5 × that maximum, and conflicts above it. No minimum or typical
  range is invented. Before this, such records were skipped: a described size could
  neither support nor count against 4,610 Global, 384 Tropical Pacific and 4 Caribbean
  records.
- **Widths are never compared as lengths.** A record measured as a disc or carapace
  width gets no size evidence either way.
- **No size:** a record with no size stays neutral.

`SpeciesRankingInput.preferredRegions` carries the diver's optional “where are you
diving?” choice. A species recorded in any preferred region gets an ordering-only boost.
That boost is not description evidence: it never changes eligibility, confidence or
explanations.

Retrieval scales are normalized separately before fusion:

* cosine similarity uses `clamp((score + 1) / 2, 0, 1)`;
* BM25 uses the saturating transform `score / (score + 3)` for positive scores.

The final ordering score is structured evidence score plus eight times normalized
retrieval relevance plus the catalogue occurrence prior plus the preferred-region boost,
minus the out-of-range penalty when it applies. Raw BM25 and cosine values
are never added to each other or directly to structured evidence. The occurrence
prior affects ordering only; it is not emitted as matched evidence and cannot make a
candidate eligible.

## Confidence and explanations

User-facing confidence is derived only from the structured evidence score and the
observation information level, not from retrieval relevance or the occurrence prior.
Semantic fallback results are always `limited` information and cannot turn cosine
similarity into an identification probability. Vague structured queries remain capped at the
existing limited-information ceiling.

Structured explanations continue to name only catalogue-backed clue matches and
conflicts. Semantic retrieval adds only “catalogue description similarity”; it does
not infer or invent a particular trait. Results are deduplicated by stable species ID,
sorted deterministically by final score, name, and ID, and capped at ten.

The controlled semantic fixtures in the contract tests are synthetic. They exercise
the ranking boundary and do not claim real-model retrieval quality. This pass does
not add Core ML, change the production engine default, or tune against holdout data.
