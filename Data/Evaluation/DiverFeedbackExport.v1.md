# Diver feedback export, schema v1

The Dive ID app can save a diver's answer to "Was this right?" after a description
search, on the device only. **Nothing is sent automatically.** The diver chooses
**Share my feedback** (Home → Data Sources and Credits). The app shows a count and a
preview, then the iOS share sheet sends one JSON file wherever the diver picks.

This file is **candidate intake material** for the independent pilot
(`IndependentDiverCollection.md`, `IndependentProtocol.v1.json`). It is not a frozen
observation dataset, and it never verifies an identity:

- `claimedSpeciesID` is the diver's own answer, given **after seeing app results**.
  The protocol states that app-returned identities are never verification evidence.
  A curator who has not seen engine output still assigns `label` independently, from
  photo or guide evidence.
- Only `firstSearchOfInstall: true` records were written before the diver had seen
  any app results (`priorExposure: false`). Every later search is exposed.
- The diver wrote the description in the app, not on the Contributor form. The
  custodian decides whether a record is eligible, and records why in the intake log.

## File

```json
{
  "schemaVersion": 1,
  "format": "diveid-diver-feedback",
  "exportedAt": "2026-10-28T12:30:00Z",
  "participantCode": "DIVER-7KQ2M9XA",
  "note": "…claimedSpeciesID is the diver's own answer…",
  "records": [ … ]
}
```

Dates are ISO 8601 (UTC). Keys are sorted. Only records with
`consentForEvaluation: true` are included, oldest first.

## Record

| Field | Type | Meaning |
|---|---|---|
| `feedbackID` | UUID | This record. Stable if the diver changes their answer. |
| `attemptID` | UUID | The search. One record per search; a new answer replaces the old one. |
| `createdAt`, `updatedAt` | date | First saved; last changed. |
| `appVersion`, `appBuild`, `buildChannel` | string | App build (`debug`, `internal`, `release`). |
| `packID`, `catalogueVersion` | string, int | The pack searched and its `packVersion`. |
| `participantCode` | string | Random per install (`DIVER-` + 8 characters), never derived from the device. |
| `originalDescription` | string | Exactly as typed when Find Matches was pressed: **not trimmed or edited**. The search itself used the trimmed text. |
| `firstSearchOfInstall` | bool | The first search ever made on this install. |
| `researchOfAttemptID` | UUID? | Set when the diver went back from results and searched again on the same screen: the earlier attempt. |
| `editedAfterSeeingResults` | bool | That re-search used different text from the earlier attempt. |
| `shownResults` | `[{rank, speciesID}]` | The results as displayed, top ten, rank order. |
| `answer` | string | `claimedSpecies`, `none` or `notSure`. |
| `claimedSpeciesID` | UUID? | With `claimedSpecies`: the species the diver says they saw. |
| `broadRegion` | string? | Optional, typed by the diver (no coordinates are collected). |
| `approximateDepth` | `{value, unit}`? | Optional; `unit` is `metres` or `feet`. |
| `uncertainty` | string? | Optional "anything you're unsure about". |
| `hasPhotoToSend` | bool | The diver says they have a photo they could send separately. |
| `consentForEvaluation` | bool | "Use my descriptions to test Dive ID". Always true in an export. |
| `consentForPublication` | bool | "Dive ID may quote my wording". Separate; evaluation consent never implies it. |
| `priorExposure` | bool | True for every search after the install's first, since the diver has seen results. |
| `source` | string? | `description` or `photo`. Absent on records saved before photo search existed: those are descriptions. Photo search runs only in Debug and Internal builds. |
| `recognizerID`, `recognizerVersion` | string? | Photo searches only: the recognizer that ran. The diver's photo is never stored in feedback or exported. For a photo search, `originalDescription` is the optional "anything else you noticed" text. |

Collected nowhere: location data, contacts, names, device identifiers or advertising
identifiers. Consent is per install. Changing it in Data Sources and Credits applies to
every saved record, so withdrawing evaluation consent removes older records from the
next export.

## Mapping to the independent-v1 custodian fields

| independent-v1 | From this export |
|---|---|
| `observationID` | Assign at intake (a new UUID). `feedbackID` can be kept in private provenance. |
| `description` | `originalDescription`, unchanged. |
| `collectionDate` | Date part of `createdAt`. |
| `region` | `packID` (the pilot searches `global`). |
| `language` | `en` only after the custodian confirms it; not detected by the app. |
| `author.participantID` | `participantCode`. `attestsOwnUnpromptedWords` must be obtained from the diver; the app does not ask it. |
| `consentForEvaluation`, `consentForPublication` | Same fields. |
| `priorExposure` | `priorExposure`, OR'd with anything else the custodian learns. |
| `observationContext` (private) | `broadRegion`, `approximateDepth`, `uncertainty`, `hasPhotoToSend`. |
| `label` | **Not from this file.** Curator-assigned from independent evidence; `claimedSpeciesID` and `shownResults` are engine-exposed. |

## Storage on the device

`Application Support/DiveID/diver-feedback.json`:
`{"schemaVersion": 1, "records": [record…]}`, same record shape (including records
without evaluation consent). A newer `schemaVersion` or unreadable file is reported,
never reset, with the same retry behaviour as saved identifications. Feedback is never
read by search, ranking or result order.

Synthetic fixtures: `DiveIDTests/Fixtures/DiverFeedback/Feedback*.json` (marked
`SYNTHETIC`; never treat them as diver accounts).
