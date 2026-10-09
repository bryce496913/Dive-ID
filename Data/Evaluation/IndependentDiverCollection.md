# Independent diver-description collection (empty pilot)

Collect 12 independently written observations after the v1 criteria are frozen:
4 Caribbean and 8 Pacific, including short accounts and uncertain observations.
Do not show contributors the catalogue, synthetic examples, engine results or
expected species names before they submit their own unedited text. Obtain consent
for evaluation use; use pseudonymous participant IDs and omit precise sensitive
locations and personal information. No observations have been collected yet.

Keep submissions outside fixtures and tuning datasets in an access-controlled
holdout location. A curator who has not seen engine output assigns supported
identities, acceptable alternatives, rank bounds and exclusions using independent
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
