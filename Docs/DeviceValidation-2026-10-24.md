# Installed-app validation on a physical iPhone (2026-10-24)

> Superseded: these rows were executed on an iPhone 14 Pro on 2026-10-25; see
> `DeviceValidation-2026-10-25.md`.

**Physical-device status: unexecuted.** This run was made from a Linux cloud container
with no Mac, no Xcode, no paired iPhone and no remote device session, so nothing was
built for, installed on, or observed on a phone. Every physical row below is
**unexecuted**; no timing, offline or hands-on observation is claimed. Simulator and
automated results are reported separately and are not device evidence.

The machine-readable record is `Reports/DeviceValidation.2026-10-24.json`. The general
procedure is `InstalledReleaseValidation.md`; this record refreshes its expectations
to the current catalogue and adds the checks requested on 2026-10-24.

## Candidate

| Field | Expected / current | Observed on device |
| --- | --- | --- |
| Commit | Branch `claude/quirky-darwin-hjjg7c` head `b138001` (UI repair `217cdc4` plus the Core ML fixes). Not yet on main; the device candidate is the main merge commit that contains them **after** hosted UI tests pass on it. Record the full SHA. | unexecuted |
| App version / build | `MARKETING_VERSION` 0.5, `CURRENT_PROJECT_VERSION` 2 (project file); confirm from resolved Release settings and the built Info.plist | unexecuted |
| Bundle ID / team | `com.brycecameron.DiveID`, team `7ZAXQ2686Z`, automatic signing, iOS 18.0 minimum | unexecuted |
| Configuration | Release (`-configuration Release`); DEBUG absent; no `DIVEID_INTERNAL`; `DiveID/Resources/SemanticSearch` absent | unexecuted |
| Device model / iOS | — | unexecuted (no device) |
| Search engine | `productionBM25` (`DescriptionRetrievalEngine.productionDefault`; Release has no experimental switch or diagnostics) → BM25 retrieval plus biological ranking | unexecuted: needs an Instruments Time Profiler trace showing `BM25SpeciesCandidateRetriever` / `LocalSpeciesRanker` |
| Catalogue (Global) | pack version 24; 4,798 bundled; **4,796 searchable** (verified, with categories); drafts excluded: Graceful shark, Silky shark | unexecuted |
| Catalogue (Caribbean) | pack version 3; 8 bundled; **2 searchable** (Atlantic Blue Tang, Queen Angelfish) | unexecuted |
| Catalogue (Tropical Pacific) | 1,000 bundled; **0 searchable**; region unavailable | unexecuted |
| Catalogue fingerprint (Release access) | Global `f05456831f0f395a10c81f8ee79dd1bcd2178b6ab9935b54e1e0f5469373c0a9`; Caribbean `7af68dfc8c3b7b0c1e3a7887d61fa13aa89383a4ccbd48c9946031543180d944` (`SpeciesSearchDocument.catalogueFingerprint` of the publication-access documents) | unexecuted; Release does not display it, so on the device compare the packaged `Creatures.json`/`PackManifest.json` bytes (`validate_device_release.py`) |

The counts were confirmed on 2026-10-24, not assumed. The reviewed baseline of
4,798 Global records (4,796 approved, 2 drafts) still holds. Every pack's
verified-with-categories ID set equals the approvals oracle
(`Tools/CatalogReview/publication_expectations.py`) and
`DiveIDTests/Fixtures/PublicationApprovedIDs.json` exactly. The fingerprints were
computed by the app's own Swift code under SwiftPM on Linux. That is automated
evidence: it shows what a correct installation should load, not what a phone loaded.

## Prerequisite: the UI repairs are not yet validated

These repairs exist only on the branch and were not run on a simulator after the change:

- `217cdc4` fixes the largest-text Find Matches defect. Hosted run 40103213891 showed
  the button above the keyboard but not hittable: the growing editor, a UIKit view,
  covered the pinned bar. The fix also makes the main UI-test pass use a non-SE iPhone;
  until now both passes ran on the iPhone SE.
- The species-detail `toggleSaved` reachability at the largest text size is still
  undiagnosed. That flow never got past the Find Matches tap.

Run the hosted UI tests on a PR, then build the device candidate from the merged commit.

## Build and install (Mac with Xcode 16.4 and the paired iPhone)

Follow `InstalledReleaseValidation.md` § "Capture and build on a Mac", with these
additions:

```bash
set -euo pipefail
test ! -e DiveID/Resources/SemanticSearch          # Release must not carry semantic artifacts
python3 Tools/CI/validate_device_release.py --settings "$EVIDENCE/release-settings.json" \
  --app "$APP" --output "$EVIDENCE/product-check.json"   # signed iphoneos Release, no DEBUG,
                                                        # packaged bytes = candidate, IDs = approvals
xcrun devicectl device info details --device "$DEVICE_ID" --json-output "$EVIDENCE/device.json"
```

The checker fails unless the built product is a signed iPhoneOS Release product with
no DEBUG flag. It also checks the packaged catalogue bytes against the candidate, and
the eligible ID set in each pack against the approvals oracle. Record the model and
iOS build from `device.json`.

## Expected versus observed (physical iPhone, Release, BM25)

Set up the radios first. Turn on Airplane Mode, then switch Wi-Fi off and cellular
data off explicitly in Settings, and screenshot all three. Keep them off for every
row. The frozen descriptions come from `DiveIDTests/Fixtures/V05Development.v2.json`
and are entered verbatim.

| # | Check | Expected | Observed |
| --- | --- | --- | --- |
| D1 | Fresh install opens | New install selects Global; Home shows "Dive region: Global", 4,796 species; Photo card visible but disabled ("Coming later") | unexecuted |
| D2 | First search after launch | Global, query G (below) → ranked results with Spotted Eagle Ray (`…0010`) present, no spinner hang; then repeat G and two other cases in the same process | unexecuted |
| D3 | Positive / ambiguous / no-match | Caribbean (its frozen cases target it). Positive `v05-01-diagnostic` ("Compressed blue reef fish with a yellow spine beside its tail."): Atlantic Blue Tang within its original rank bound. Region conflict `v05-region-1` ("…on a reef in Fiji."): a region mismatch, not wrong-pack results. Ambiguous ("Dark angelfish near a Caribbean reef.", Caribbean): conservative, confidence ≤ 0.64. No-match ("A fish moved past me.", "A spotted freshwater frog on sand, about 5 cm long."): the no-match state, distinct from a loading error | unexecuted |
| D4 | Find Matches with keyboard open | With the keyboard up after typing, the whole button sits above the keyboard and one tap dismisses the keyboard and submits; repeat after Done and refocus, and with a description of several lines | unexecuted |
| D5 | Largest text size | Settings → Accessibility → Display & Text Size → Larger Text → largest. Repeat D4; title wraps, not clipped; open the top result and reach Save Identification by scrolling | unexecuted |
| D6 | Results → detail | Each tapped result opens that species' detail (name matches the tapped card); back returns to the same results without re-running | unexecuted |
| D7 | Region switching | Global search → open detail/back → Change Dive Region → Caribbean → search; Caribbean results contain only its 2 approved species; earlier Global results keep their region | unexecuted |
| D8 | Unavailable selected region | Needs a previous installation that selected Tropical Pacific while it was selectable (Debug with the same bundle ID); install this Release in place. Expected: "Selected region unavailable", Change Dive Region offered, Global/Caribbean selectable and searchable, choice persists after relaunch | unexecuted (needs prior installation; not to be simulated with `defaults write` or launch arguments) |
| D9 | Cancel then search again | Start search A, back out at once, submit different case B; ×10 incl. detail/back and background/foreground. B's results only; no stale replacement, no stuck spinner. If A always finishes before navigation, record "cancellation not observed" | unexecuted |
| D10 | Save → terminate → relaunch → reopen | Save a result; force-quit from the app switcher; relaunch from the icon; Saved Identifications lists it; detail shows the same species, region and description | unexecuted |
| D11 | Remove → relaunch | Remove the save; force-quit and relaunch; it is gone | unexecuted |
| D12 | UI never blocks | During the first search after a fresh install (index built in the background), the screen scrolls and the keyboard responds; no hang over ~250 ms visible in the recording | unexecuted |

## Timing (physical iPhone only; none recorded)

Record each trial on screen, at 60 fps or more (note the frame rate and resolution),
with no debugger attached and in a stable thermal state. Count frames between the
boundaries below. Use the same query every time. Query G, in Global, is the hosted UI
tests' text "Large flat eagle ray with white spots and a long tail over sand in the
Caribbean." Spotted Eagle Ray is approved in Global. Repeat the warm series with
`v05-01-diagnostic` in Caribbean, and report it separately per pack. Keep
every raw sample and record failed trials separately; never record a failure as zero.

| Measure | Boundary | Trials | Report |
| --- | --- | --- | --- |
| Launch-to-search readiness, fresh install | Icon tap → first frame with Home showing the region and an enabled Describe action; then Describe → editor ready | 5 (uninstall + install before each, on a dedicated device before the persistence rows) | each value, median, range; no p95 (n = 5) |
| Launch-to-search readiness, later launch | Same, after force-quit, index archive present | 5 | median, range |
| First-query latency, fresh install | Find Matches tap → first frame of stable results | 5 (the first search of each fresh install, when no index archive exists yet) | median, range |
| First-query latency, later launch | Same, first search after relaunch (archive loaded, not rebuilt) | 5 | median, range |
| Warm-query latency | Same, 20 searches in one running process | 20 | median, nearest-rank p95 = sorted sample ⌈0.95·n⌉ |

"Fresh install" removes the app's caches and index archive. It does not clear the
operating system's own file caches, so none of these figures are claimed as truly cold.
Release has no signposts. If you need component-level times, use the Internal
configuration's signposts ("Catalogue load", "Index build", "Background preparation",
"Query to first result"), and report them as Internal: it opens the draft catalogue
and is not Release.

## Experimental semantic check (separate configuration; not run)

This check applies only once genuine artifacts exist. Semantic run 40105492969
produced and packaged a real Core ML encoder with passing numerical parity, but the
app rejected its vocabulary fingerprint (fixed in `b138001`). Run 40107408712 was still
executing when this record was written. Until that run shows "actual engine: Core ML
semantic" on the hosted app, a device check would only exercise the fallback.

When it passes, on a Debug build:
1. Download that run's `semantic-global-resources` artifact and copy it to
   `DiveID/Resources/SemanticSearch/`.
2. Install with `-configuration Debug`.
3. Launch with
   `xcrun devicectl device process launch --device "$DEVICE_ID" com.brycecameron.DiveID -DiveIDExperimentalSemanticSearch YES`.
4. Search, and record the diagnostics bar's "Requested engine" and "Actual engine"
   lines and any "Fallback" line.

Expected: requested and actual are both "Core ML semantic + BM25", with no fallback.
Report this as Debug and experimental, apart from the Release rows, and never ship it
in Release.

## Automated and simulator evidence (separate; not device evidence)

| Source | Result |
| --- | --- |
| Approvals vs packaged source (this run, Linux) | Global 4,796/4,798, Caribbean 2/8, Tropical Pacific 0/1,000 eligible; all equal the oracle and fixture |
| Release-access catalogue fingerprints (SwiftPM, Linux, this run) | As in the candidate table |
| Hosted Debug unit tests, iPhone SE simulator iOS 18.6 (run 40103213891, main `96aab8d`) | Passed: `IdentificationLifecycleTests` (late success cannot replace newer results; route abandonment cancels and rejects late completion; immediate restart cannot be overwritten), `SearchIndexStoreTests` (background preparation reused by the search; a cancelled request returns at once; later launch loads the archive), `SavedIdentificationPersistenceTests` / `SavedIdentificationCompatibilityTests` (save/remove survive new repository instances), `SelectedPackStateTests` (selected region without a reviewed pack is unavailable) |
| Hosted UI tests, same run (both passes were on the SE) | Smoke flow, normal-size keyboard, new install in Global, Photo disabled/Saved: passed. Largest-text keyboard and largest-text layouts: **failed** (Find Matches covered by the editor) → fixed in `217cdc4`, not yet re-run |
