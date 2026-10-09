# Spine observation regression

The source-corrected catalogue made Queen Angelfish eligible for a solitary
observation. In Caribbean case realistic-029, retrieval recalled Red Lionfish but
structured ranking displayed it fourth: the parser recognized fish, reef, long,
and solitary while discarding the diagnostic noun needles. The previous top-three
result depended on missing catalogue evidence for a competing species.

Normalize ordinary spine descriptions (spiny, spiky, needles) into the existing
spines clue group. These vocabulary aliases apply to every species and use existing
whole-token matching. They do not add evidence groups, change scoring weights,
boost a species, or alter the source-backed catalogue. Tests check equivalent
forms and reject substring matches in needlefish, spineless and spinnaker.

Full Linux SwiftPM Debug and Release: 107 tests each, zero failures, one opt-in
frozen evaluation skipped. The unchanged Caribbean structured development gate
now measures top-1/3/10 of 41/43/45; hybrid remains 43/44/45. Both have candidate
recall 56/56 and correct no-match 14/14. Case realistic-029 displays at rank 2 in
both engines. Full Pacific bounds pass (waspfish 1, dartfish 5, puffer 6).
This correction precedes the broader v0.5 evaluation; no new evaluation cases
were run to select these aliases. Xcode/device execution is not claimed.
