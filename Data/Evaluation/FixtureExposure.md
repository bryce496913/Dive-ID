# Existing fixture exposure and independent-data boundary

Inventory before independent collection (2026-10-11 UTC). No independently collected
human descriptions have been supplied. A file name containing “diver” or a split
named “holdout” does not establish independent human provenance.

| Fixture | Cases | Exposure / permitted interpretation |
| --- | ---: | --- |
| V05Development.v1 / v2 | 46 each | Synthetic source-informed development descriptions. v2 is an identity/pack erratum, not a new independent sample. These cases influenced location recognition, domain exclusions, evidence transfer/ranking, measurements, morphology and source corrections. |
| TropicalPacificDiverDescriptions.v1 | 7 | Public source-cited regression descriptions, including waspfish/dartfish repair diagnostics. No independently collected human provenance established; development only. |
| CaribbeanLimitedDescriptions.v1 | 6 | Public development quality gate. No independent collection provenance established. |
| CaribbeanIdentificationBenchmark | 100 (70 development, 30 nominal holdout) | Public benchmark used by regression tooling. Nominal holdout is developer-accessible and has no established independent human collection provenance; do not market it as a fresh independent human holdout. No holdout wording is reproduced here. |
| Inline parser/service/ranking tests | Not a dataset | Implementation-exposed regression examples, not independent observations. |

See Reports/LocationCompatibilityValidation.md, Reports/DomainEligibilityValidation.md,
Reports/RankingEvidenceValidation.md and Reports/MorphologyValidation.md for the
record of development influence. Existing acceptance fixtures remain unchanged.

Future independent data uses IndependentDiverCollection.md and IndependentProtocol.v1.json.
The custodian keeps source text, identities, exposure history and raw results outside
the repository. Only aggregate results are released. Authorship and identity verification
are separate attestations, not facts software can prove. Maintain an append-only exposure
ledger across versions: the importer enforces cohort consistency within each import,
but cannot detect a custodian deleting history or falsely resetting exposure flags.
Any author/encounter cohort exposed to development is permanently development data.
