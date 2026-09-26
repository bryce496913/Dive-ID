# Tropical Pacific description-search pass

## Scope and execution status

Fresh Linux SwiftPM execution on 2026-09-26 used the unchanged version 2
Tropical Pacific development pack (384 draft records), selected the fixture's
`tropical-pacific` pack, and ran the production-default
`HybridDescriptionSearchEngine`: BM25 retrieval with a 50-candidate limit,
followed by `LocalSpeciesRanker` and the service's ten-result presentation
limit. The seven fixture descriptions, expected IDs, acceptable maximum ranks,
and frog no-match assertion were not changed. The publication configuration
still excludes this draft-only pack.

The repository's previous trace described three historical failures. A fresh
pre-change fixture run instead reproduced exactly two: Fire Dartfish and
Cockatoo Waspfish. Ribbontail Ray ranked 1, Dragon Moray ranked 1,
Blackspotted Puffer ranked 6, the short Bluespotted Ray ranked 1, and the frog
correctly produced no result. Those are fresh observations; the earlier ranks
below are labelled historical rather than presented as a rerun.

## Current traces

“Retrieval rank” is the expected record's BM25 rank over all 384 documents.
“Displayed rank” is its position after the production 50-record boundary,
structured eligibility/scoring, the ranker's ten-result limit, and service
presentation.

| Case | Parsed structured observations | BM25 evidence (score; rank) | Survives 50 | Structured decision | Historical displayed | Fresh displayed after correction |
| --- | --- | --- | :---: | --- | ---: | ---: |
| Fire Dartfish | category `fish`; colors `orange`, `red`; marking `tail`; behavior `hovering` | `above`, `burrow`, `fish`, `hovering`, `red`, `tail` (15.37792039201181; 1) | yes | eligible; support `fish`, `tail`, `red`, `hovering`; no contradictions; raw 15 | absent | 5 |
| Cockatoo Waspfish | category `fish`; color `brown`; behavior `bottom-swimming` | `bottom`, `dorsal`, `fish` (4.693223201117945; 81) | **no** | eligible only when diagnosed in isolation; support `fish`; no contradictions; raw 6 | absent | absent |

Fire Dartfish historically retrieved at rank 13 and survived the boundary, but
its incomplete structured record left it outside the displayed top ten. After
the source-backed overlay, the corrected traits also improve its search
document, so fresh retrieval is rank 1 and final ranking is exactly the
fixture's maximum acceptable rank 5. This was a catalogue-data defect, not a
candidate-limit or final-ranking defect.

Cockatoo Waspfish remains a retrieval miss: rank 81 never enters the production
pool. Giving the ranker that candidate solely for diagnosis shows that its
current structure would be eligible, but only on generic `fish` support and at
raw score 6. It would still lack support for the fixture's leaf shape, brown
color, sail-like dorsal fin, and rocking behavior. Raising the limit or adding
a species/query-specific rule would conceal the incomplete source data and was
not done.

## Evidence-backed correction

The workbook's high-confidence Fire Dartfish species-account transcription is
source-bound to *Reef Fish Identification: Tropical Pacific*, species account
book p. 282 (PDF p. 283), source ID `SRC-E19DD980`. It states “reddish brown
rear body” and “Hover above burrows”. The importer previously extracted
`brown` but not the red color concept from `reddish`, and `solitary` but not
`hovering` from the verb `Hover`. The review overlay therefore adds only `red`
and `hovering`, retaining the already extracted colors and behavior. The
decision remains `draft`, names the unresolved independent source-page and
taxonomy review, and does not confer publication approval. Reimport applies
the correction reproducibly and records its fingerprint/outcome in the import
report.

No general retrieval or ranking correction was justified: with the supported
traits present, the existing production pipeline meets the Fire Dartfish bound
without changing limits, weights, eligibility, confidence, or search-document
wording.

## Unresolved source evidence

The Cockatoo Waspfish workbook record is source-bound to the same book,
species account p. 381 (PDF p. 382), source ID `SRC-B853F73C`, but its only
high-confidence text is comparative: “Similar to Spiny Waspfish (previous)”
and the explicit differences are dorsal-spine count and occurrence alone. It
does not state the leaf shape, brown color, sail-like fin, or rocking behavior
needed by the fixture. The source scan itself is not stored in the repository.

The fixture points to the Fishes of Australia Cockatoo Waspfish account as an
independent authoritative reference, but this environment could not retrieve
that page: the web provider returned HTTP 401 and direct HTTPS access was
blocked by the network proxy with HTTP 403. The exact missing evidence is a
retrievable source passage tying *Ablabys taenianotus* to (1) leaf-like body
shape, (2) brown coloration, (3) a high/sail-like dorsal fin, and (4) swaying
or rocking behavior. Until that evidence can be inspected, no overlay copies
the preceding species' traits and the top-5 assertion deliberately remains
failing and visible.

SwiftPM exercised the portable service, retrieval, ranking, no-match, and
confidence behavior. Xcode-hosted bundle, iOS Simulator, device build, Core ML,
and device performance/thermal checks were unavailable in this Linux pass.
