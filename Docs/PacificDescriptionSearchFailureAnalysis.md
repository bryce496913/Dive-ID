# Tropical Pacific description-search pass

This pass used the version 2 Tropical Pacific development pack (384 draft
records) and the production-default `HybridDescriptionSearchEngine`: BM25
retrieval with a 50-candidate limit followed by `LocalSpeciesRanker`. The
publication configuration correctly excludes this pack, so these are portable
development-fixture results rather than publication or hosted-iOS validation.

## Trace results

“Candidate rank” is the expected record's rank in an untruncated BM25 retrieval
over all 384 documents. “Displayed rank” is its position after the 50-record
limit, structured eligibility and scoring, the ranker's ten-result limit, and
the identification service's ten-result presentation limit.

| Case | Candidate rank | Survives 50 | Before displayed | After displayed | Classification |
| --- | ---: | :---: | ---: | ---: | --- |
| ribbontail ray | 1 | yes | 1 | 1 | passing control |
| dragon moray | 1 | yes | 1 | 1 | passing control |
| fire dartfish | 13 | yes | absent | absent | ranking plus source-data structure |
| cockatoo waspfish | 81 | no | absent | absent | retrieval plus source-data structure |
| blackspotted puffer | 9 | yes | absent | 6 | candidate filtering |
| bluespotted ray (short) | 1 | yes | 1 | 1 | passing control |

The freshwater-frog no-match control returned no results before and after.

## Evidence and conclusions

* **Blackspotted puffer:** BM25 retained the record at rank 9 with `black`,
  `puffer`, and `spot`. The parser kept terminal `spots.` as a punctuated token,
  however, so structured markings were empty and the short observation failed
  eligibility. Splitting observation tokens at punctuation restores the
  source-backed `spots` marking. Its structured support is `black` and `spots`,
  with no contradiction; it now has raw score 7, limited information, relative
  confidence 0.167, and displayed rank 6.
* **Fire dartfish:** retrieval was not the failure: the record was rank 13 and
  survived the 50-candidate boundary, matching `above`, `burrow`, `fish`, and
  `tail`. Before correction, structured support was `fish`, `tail`, and an
  inferred `white`, with no contradiction and raw score 13; after removing that
  unsupported inference, support is `fish` and `tail` (raw score 10). In both
  runs, competing records push it beyond the ten ranked results. The draft
  record's structured colors omit the description's
  red/orange rear (although its source transcription says “reddish brown”), and
  its structured behaviors contain only `solitary` even though the source
  transcription says it hovers above burrows. Completing those fields requires
  source review; this pass does not silently alter draft biology.
* **Cockatoo waspfish:** the expected record was BM25 rank 81, matching only the
  broad `bottom`, `dorsal`, and `fish` terms, and therefore did not survive the
  production candidate limit. With an untruncated retrieval signal it has only
  structured `fish` support (raw score 6) and no contradiction. Its account is
  explicitly comparative (“Similar to Spiny Waspfish (previous)”), while the
  preceding Spiny Waspfish record contains the brown, sail-like dorsal fin, and
  swaying traits used by the fixture. Resolving inherited comparative text into
  the Cockatoo Waspfish record is a source-review decision. Increasing the
  production limit, copying traits, or adding a species-specific boost would
  conceal that defect, so the top-5 failure remains visible.

## General correction

The implementation now removes punctuation at the token boundary while leaving
normalized decimal text intact for measurement parsing. It also stops treating
the relative-lightness word `pale` as affirmative evidence of white coloration;
this prevents an unsupported white clue from promoting competing spotted fish.
Structured scoring, retrieval evidence, biological constraints, deterministic
ordering, and confidence limits remain unchanged.

No descriptions, expected IDs, rank bounds, no-match assertions, catalogue
documents, candidate limit, production-engine selection, confidence limit, or
draft catalogue record was changed.
