# Independent diver-description collection (empty pilot)

Collect 12 independently written observations after the v1 criteria are frozen:
4 Caribbean and 8 Pacific, including short accounts and uncertain observations.
Do not show contributors the catalogue, synthetic examples, engine results or
expected species names before they submit their own unedited text. Obtain consent
for evaluation use; use pseudonymous participant IDs and omit precise sensitive
locations and personal information. No observations have been collected yet.

Keep submissions outside fixtures and tuning datasets in an access-controlled
holdout location. Rank bounds are fixed by IndependentProtocol.v1.json. A curator who has not seen engine output assigns supported
identities, acceptable alternatives and exclusions using independent
photo/guide evidence. Uncertain identity can be excluded with a recorded reason;
never select cases based on whether the engine succeeds. Freeze a manifest and
hashes before a single evaluation. Do not publish raw text without consent.

Record one entry per observation:

- observationID, pseudonymousContributorID, consentForEvaluation, consentForPublication
- originalUneditedDescription, originalLanguage, collectionDate, broadDiveRegion
- approximateDepthAndUnits, approximateLengthAndUnits, uncertainty (optional)
- evidenceLocator (photo/field guide; separately permissioned), identityConfidence
- curatorIdentity, adjudicationDate, expectedSpeciesIDs, acceptableSpeciesIDs
- expectedKind, maximumAcceptableRank, maximumConfidence, exclusionReason
- collectionProtocolVersion, frozenCriteriaVersion, holdoutManifestHash
- priorExposureToCatalogueOrEngine, firstEvaluationDate, tuningAccessGranted (false)

Use the same service-path runner only after importing a reviewed, consented,
frozen manifest into a separately named holdout version. Never relabel these
synthetic development descriptions as independent human submissions.

## Contributor form (show only this section to the diver)

Please describe one marine animal you remember seeing, in your own words. Write
what you recall before looking anything up. It is fine to leave details unknown.
Do not use the identification app or an AI writing assistant to compose this.

- Your account: what did it look like, and what was it doing?
- Where was it relative to its surroundings? What do you recall of the habitat?
- About how deep were you, and in what units? Leave blank if uncertain.
- Broad location/region and approximate observation date (no sensitive coordinates).
- Anything you are uncertain about, or could not see clearly?
- Optional original photo/video or instructor contact reference for a separate
  verifier. Do not insert a looked-up species description into your account.
- May we use this unedited account for evaluation? May we publish the wording?
  These are separate optional consents. Use a participant code, not a public name.
- Had you already seen this app, catalogue descriptions or its search results?

A collector records collection date, participant code and original language. Do
not correct wording, add missing traits, suggest synonyms or show model examples.
Keep proposed identities and verification material off the contributor-facing form.
No outreach or invitation may be sent without explicit authorization.

## Custodian import fields

Use JSON `{schemaVersion: 1, protocolVersion: "independent-v1", datasetVersion:
"<immutable cohort version>", observations: [...]}`. This is a schema guide, not
an observation dataset. Each observation requires:

- `observationID`: a UUID assigned at collection, retained across versions;
  `description`: original unedited English account; `collectionDate`: YYYY-MM-DD;
  `region`: caribbean or tropical-pacific; `language`: en.
- `author`: `{kind: "human", participantID: "<pseudonym>",
  attestsOwnUnpromptedWords: true}`; `consentForEvaluation`: boolean. Keep publication
  consent separately; evaluation consent never grants publication rights.
- `cohortID`, `encounterID`: custodian IDs. All observations from a participant or
  shared encounter must be in the same cohort (merge connected groups before
  assignment). Keep cohort IDs stable; never search for a favorable split hash.
- `priorExposure` and `usedForDevelopment`: booleans. An affirmative flag promotes
  the whole cohort to development. Keep an append-only exposure ledger, never reset
  these flags or recycle a holdout after its wording/results informed development.
- `label`: `{kind, acceptableSpeciesIDs, verifierID, verificationDate,
  verifiedWithoutAppResults, notes, evidenceReferences}`. Kind is identification,
  ambiguous, noMatch, regionConflict or unresolved. Use stable catalogue UUIDs for
  independently established acceptable species, including multiple defensible
  alternatives. A label may remain unresolved, with an empty identity set and no
  verifier decision; it is retained but excluded from quality metrics.

The verifier must differ from the author, work without app results, and cite
original photo/video plus an authoritative taxonomic/field reference or documented
instructor assessment. Record scientific identity and any limitations in notes.
URLs are not required for private evidence: use durable, separately permissioned
asset/reference locators. App-returned identities are never verification evidence.
A noMatch label requires independent evidence of an out-of-domain subject or another
explicit abstention contract, not merely absence of the expected species in a pack.
An ambiguous label requires a defensible nonempty alternative set; otherwise use
unresolved. Region conflicts are verified against the selected pack's scope.

## Frozen baseline procedure (custodian only)

The versioned rules are in `IndependentProtocol.v1.json`. Existing development
gates remain unchanged. The 12-case pilot is not large enough to establish quality;
collect prospectively, without choosing accounts based on app success. English-only
v1 inclusion is a tooling limit: retain non-English submissions for a separately
specified cohort rather than silently translating them. Retain rejected submissions
with reasons outside the repository. Remove personal/sensitive information before
consented collection; do not silently edit already collected observation wording.

Use a clean committed checkout. Store original submissions and outputs outside the
repository in access-controlled custodian storage; local mode 0700/0600 checks are
only a filesystem safeguard, not encryption or an organizational access boundary.
Do not run this in shared development CI with holdout secrets or upload raw logs.

```sh
python3 Tools/Evaluation/independent_divers.py freeze \
  --source /secure/diver-submissions.json --private-dir /secure/cohort-v1
python3 Tools/Evaluation/independent_divers.py evaluate \
  --private-dir /secure/cohort-v1 --swift /path/to/swift
```

Freeze validates provenance and labels, assigns stable cases and group-level splits,
and locks protocol, source provenance, case bytes, application commit and catalogue
hashes before invoking the engine. Evaluation runs production BM25/biological ranking
through LocalMarineLifeIdentificationService against both catalogue access modes.
Raw case ranks, errors and logs stay private. Only aggregate counts/rates leave the
custodian directory; no case IDs, wording, expected identities or failure lists go
into development output. Empty/missing publication coverage is not a no-match pass.
Scores remain relative strengths, not calibrated probabilities. Sampling error and
shared-author dependence limit inference even when screening thresholds pass.

If text or a failure is used for enrichment, mark the entire cohort exposed in the
ledger, move it to development in a new version, and preserve the previous manifest
and baseline. Freeze a new independent holdout before evaluating further changes.
Software checks declarations and immutable hashes; it cannot prove human authorship,
verifier independence or an undisclosed exposure history. Custodian review is required.
