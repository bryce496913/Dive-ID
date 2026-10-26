# Independent diver-description collection (empty pilot)

Collect 12 independently written observations after the v1 criteria are frozen,
all searched in the Global pack (revised 2026-10-25 from 4 Caribbean and 8 Pacific;
see `IndependentProtocol.v1.json` `revisions`), including short accounts and
uncertain observations. Divers may describe animals from any region; the broad dive
region goes in private `observationContext`.
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
  `region`: the pack searched (`global` for the pilot; `caribbean` or
  `tropical-pacific` remain valid for later cohorts); `language`: en.
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

## Twelve-case pilot operations (specified before receiving submissions)

Reuse the form above and `independent-v1`; do not start another dataset format.
The target is 12 accounts, all searched in Global. Prefer one observation
per diver and independent encounters. Retain linked submissions if necessary,
record the contributor count and shared cohorts, and do not imply 12 independent
participants when there are fewer. Recruitment must not select people based on
app success. No invitation, named recipient or communication channel is authorized
by these materials. The requesting user must supply submissions or explicitly
authorize an identified custodian and collection channel before outreach.

1. **Before collection:** name the custodian and separate verifier privately; freeze
   this procedure and IndependentProtocol.v1.json at a committed SHA. Issue only
   the Contributor form, without this technical section, examples or target names.
2. **Intake:** capture the original account first, then assign a UUID observationID,
   pseudonymous participant/encounter/cohort IDs and actual collection date. Record
   evaluation and publication consent separately. A refusal of publication does
   not prevent private evaluation. Store originals/evidence outside Git. Do not
   repair spelling, grammar, terminology or missing measurements. Obtain an
   appropriate private submission before intake if it contains unnecessary personal
   information; do not silently redact an already frozen description.
3. **Context:** keep an `observationContext` object in private provenance with
   approximate observation date, broad location, habitat, depth/units and uncertainty
   as actually supplied; explicit `unknown` is valid. Record language, prior
   app/catalogue exposure and whether any writing assistance was used. Add boolean
   `consentForPublication` to the private row (false is fully acceptable). These
   provenance fields survive freeze but are not appended to the search query.
4. **Verification:** a different person reviews original photo/video and an
   authoritative identity reference, or a documented instructor assessment, before
   seeing app output. Record verifier code, actual date, evidence locators,
   scientific identity, rationale and limitations in the existing label fields.
   Confirm the UUID mapping independently against the catalogue's scientific name;
   catalogue inclusion itself is not proof of the observed identity. Broad taxon
   only or insufficient evidence remains `unresolved` with explanatory notes;
   defensible species alternatives remain a nonempty multi-ID/ambiguous label.
   Do not infer `noMatch` solely from absence in the current catalogue.
5. **Audit all 12:** custodian checks consent, verbatim preservation, evidence
   accessibility/permissions, independent author/verifier, appropriate uncertainty
   and stable ID mapping. Keep a private intake log of rejected/withdrawn records
   and reasons; do not select replacements based on search outcomes. If an identity
   cannot be verified, retain it as unresolved and report the verified shortfall.
6. **Declare pilot use:** this pilot is for collection-process development; before
   freeze, set `usedForDevelopment: true` for all pilot rows and their linked
   cohorts. This changes exposure classification, not original wording or labels.
   It does not make human wording synthetic. Never call this inspected pilot a
   fresh holdout. Prior-exposure declarations must still be truthful.
7. **Preflight, freeze, evaluate:** use the commands below from a clean committed
   checkout. Labels/criteria must be final before search runs. Retain immutable
   manifests, provenance, catalogue/code hashes, private ranks and abstentions.
   Inspect pilot failures only as development material. Do not enrich or tune in
   this pass. Publish aggregate denominators separately for development access
   (Global 4,798 records) and publication access (Global 4,796 approved); the runner
   rederives pack sizes from the frozen catalogue. Coverage blocks are not
   abstention successes.

An empty private starting document is:

```json
{"schemaVersion":1,"protocolVersion":"independent-v1","datasetVersion":"diver-pilot-v1","observations":[]}
```

Populate only with real, consented submissions using the Custodian import fields.
Do not use the synthetic unit-test payload as a participant or observation.

```sh
python3 Tools/Evaluation/independent_divers.py preflight --source /secure/diver-pilot.json
python3 Tools/Evaluation/independent_divers.py freeze \
  --source /secure/diver-pilot.json --private-dir /secure/diver-pilot-v1
python3 Tools/Evaluation/independent_divers.py evaluate \
  --private-dir /secure/diver-pilot-v1 --swift /path/to/swift
```

Preflight does not execute search, prove consent/authorship or assess whether cited
evidence is convincing. It reports counts, unresolved labels, missing context and
unrecorded publication consent without printing wording, identities or evidence.
A 12-row schema success is not completion of independent verification. Freeze
rejects empty input; unresolved labels remain outside quality denominators.

After the real pilot, report intake count, valid consent count, verified/unresolved
counts, distinct authors/cohorts, exposure flags, missing-context and import errors,
verifier disagreements and corrections needed to the process. Preserve original
labels and add versioned adjudications rather than overwriting a frozen baseline.
Report candidate recall, displayed ranks/top-k, abstentions, ambiguity and confidence
descriptively with denominators; 12 cases cannot establish identification accuracy.

## Pilot status (2026-10-25)

**Collected 0 / 12; verified 0; unresolved 0. No dataset is frozen and nothing was
evaluated.** No genuine submission exists in the repository or on the custodian Mac,
and no outreach is authorized. Preflight on the empty starting document reports 0
collected, 12 remaining, target 12 Global; freeze refuses it ("No supplied
descriptions").

Outstanding input, all from the requesting user:

1. Up to 12 genuine, consented diver accounts written before any catalogue, trait or
   app exposure, with the Contributor form answers. Alternatively, explicit
   authorization naming a custodian and a collection channel, so the custodian can
   run intake.
2. A named custodian and a separate verifier (pseudonymous codes are enough here).
3. For each account, identity evidence the verifier can review without app output:
   a photo or video, or a documented instructor assessment.

Workflow issues found and fixed before collection:

- Intake accepted only `caribbean` and `tropical-pacific`. Under Release access those
  packs offer 2 and 0 species, so the planned 4 + 8 pilot would have measured
  coverage blocks, not identification. Intake now accepts `global`, and the pilot
  target comes from the protocol (12 Global).
- Reports had no latency or abstention counts. The runner now times each service call
  (`elapsedSeconds`), and the aggregate reports median, nearest-rank p95 and maximum
  per split and access, plus abstentions per label kind. Both are descriptive, with no
  gate. Candidate recall stays separate from displayed top-1/3/10.
- The guide's pack sizes were stale (392-record development pack). It now gives the
  current Global sizes, and the runner rederives them from the frozen catalogue.

Still open, needed before any semantic comparison:

- The custodian runner is fixed to `production-bm25-50-biological`. A genuine
  semantic candidate exists locally (`Docs/RealEncoderLocalValidation-2026-10-25.md`),
  but its artifacts are generated and git-ignored, so `lock_state` cannot hash them.
  Before a comparison, freeze the encoder configuration as data: the model revision,
  compiled-model, vocabulary, contract, corpus and index SHA-256 values; the
  admission cosine (0.30, provisional and untuned); the merge rule; and
  `DIVEID_SEMANTIC_RESOURCES`. Then run both engines on the same frozen cases and
  catalogue. Do not tune either engine from the pilot.

What the pilot is: a collection-workflow check and development evidence (every row
`usedForDevelopment: true`). The committed 30/34 Global top-ten result is also
development evidence. Neither estimates independent population accuracy.

## Proposed larger collection (not authorized or begun)

Before recruitment, approve a versioned sampling manifest and independent custodian.
Propose staged intake up to 400 new accounts across the oceans Global covers,
across novice/experienced divers, different sites, depths, habitats and visibility.
Prefer one independent author/encounter per account; keep all linked groups together.
Track coverage strata at intake, without engine output: animal group (reef fish,
pelagic fish, sharks and rays, invertebrates, turtles and mammals); ocean region;
description quality (one-line recollection to detailed account, measured by trait
count, not by wording); diver experience; and whether the verifier could reach species
level. Report unfilled strata rather than filling them with generated text.
Collect recollections prospectively without catalogue prompts; describe missing
strata rather than manufacturing examples. A label-blind intake coordinator logs
completion/exclusion before engine use. A separate verifier assigns labels.

Planning targets after verification: about 200 identification cases and the
remaining 200 spread across naturally ambiguous, independently supported no-match
and regional-conflict cases. These are recruitment/coverage aims, not permission
to rewrite observations or force labels. Unresolved observations remain reported.
Do not manufacture a regional-conflict account by editing its location or selecting
a wrong pack after observing results; any controlled policy probes remain separate
synthetic development tests. If natural policy cases are scarce, report that limit.

Keep the existing deterministic cohort split: approximately 80% development / 20%
holdout by the v1 hash. Do not alter cohort IDs or rebalance after engine results.
All pilot participants/linked encounters exposed to development stay development;
reserve new unexposed cohorts for independent evaluation. Only the custodian may
see holdout wording or per-case failures; release aggregate metrics to developers.
Before any holdout run, freeze code, catalogue, criteria, case bytes and labels.

With 400 rows these aims might yield roughly 40 positive and 13 cases per policy
class in holdout, but group assignment, unresolved labels and publication coverage
can reduce counts. This is a planning estimate, not a power calculation. Existing
minimum denominators (30 positive and 10 per policy class per split/access) remain
mandatory. Regional packs with few approved species may not meet them; report insufficient
sample rather than changing thresholds or cherry-picking successful species.
At predeclared 100-row intake checkpoints, audit completeness and strata without
engine output. Any extension beyond 400 needs a new prospective collection decision;
do not collect until a quality gate happens to pass.
