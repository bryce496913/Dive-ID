# Hybrid ranking contract

`SpeciesRankingInput` is the boundary between candidate retrieval and biological
ranking. It carries the original description, its structured parse, and candidates
identified by stable catalogue IDs. Each candidate has either an explicit retrieval
signal (source, score kind, raw score, retrieval rank, and source-backed evidence) or
`nil`, which means the structured baseline was used.

## Eligibility and fusion

Structured candidates retain the existing evidence threshold and exact-name path.
A semantic candidate can also be admitted provisionally when its normalized
relevance is at least `0.65` and the description contains at least three meaningful
non-generic terms. This is intentionally independent of parser vocabulary coverage:
it permits useful paraphrases, while rejecting a high-similarity result for a query
such as “a fish on the reef.” Structured animal-group, size, and habitat conflicts
are still scored after provisional admission and can lower or remove a candidate.

## Animal-group searches (2026-10-23)

Found on device: searching "shark" or "ray" alone listed nothing in Global, although it
holds 150 shark and ray records. A one-word group name was a single clue group, so
information was `insufficient` and every candidate was rejected; "ray" (3 characters)
also could not be submitted under the 5-character minimum.

- Naming a specific animal group (any parser category except `fish`, by one of its own
  words: "shark", "rays", "octopus", "crab", "stingray", "manta") is `limited`
  information, so that group's records are listed with confidence capped at 0.64.
- "Fish" alone and vague phrases ("flat thing", although it maps to `ray`) still list
  nothing, as do the existing no-match cases.
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
Semantic admission alone is `limited` information and cannot turn cosine similarity
into an identification probability. Vague structured queries remain capped at the
existing limited-information ceiling.

Structured explanations continue to name only catalogue-backed clue matches and
conflicts. Semantic retrieval adds only “catalogue description similarity”; it does
not infer or invent a particular trait. Results are deduplicated by stable species ID,
sorted deterministically by final score, name, and ID, and capped at ten.

The controlled semantic fixtures in the contract tests are synthetic. They exercise
the ranking boundary and do not claim real-model retrieval quality. This pass does
not add Core ML, change the production engine default, or tune against holdout data.
