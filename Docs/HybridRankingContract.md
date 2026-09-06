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
such as “a fish on the reef.” Structured region, animal-group, size, and habitat
conflicts are still scored after provisional admission and can lower or remove a
candidate.

Retrieval scales are normalized separately before fusion:

* cosine similarity uses `clamp((score + 1) / 2, 0, 1)`;
* BM25 uses the saturating transform `score / (score + 3)` for positive scores.

The final ordering score is structured evidence score plus eight times normalized
retrieval relevance plus the catalogue occurrence prior. Raw BM25 and cosine values
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
