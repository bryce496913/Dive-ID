import XCTest

/// Installed-app checks for a physical iPhone running the Release build (see
/// Docs/DeviceValidation-2026-10-24.md). They assume Release catalogue access, an app
/// container this run controls and no saved identifications, so they skip unless the
/// runner sets TEST_RUNNER_DIVEID_DEVICE_VALIDATION=1. Each measurement is printed as a
/// `DEVICEVAL {json}` line so the log is the record.
///
/// Timings are observed through XCUITest: the clock starts just before the triggering
/// tap is sent and stops at the first accessibility snapshot showing the end state. Each
/// snapshot is served by the app's main thread, so the reported poll interval is both the
/// resolution of a measurement and a proxy for main-thread responsiveness while it waits.
final class DeviceValidationUITests: XCTestCase {
    static let globalQuery = "Large flat eagle ray with white spots and a long tail over sand in the Caribbean."
    static let spottedEagleRay = "result_00000000-0000-0000-0000-000000000010"
    static let atlanticBlueTang = "result_00000000-0000-0000-0000-000000000003"
    /// Indo-Pacific species (Reef manta ray, Achilles tang) that Tropical Atlantic Regions must
    /// never show. GlobalSubregionTests checks every regional result against its membership.
    static let outsideTropicalAtlantic = ["result_2b3c99d3-c4c5-5eb9-bf28-74a6b9c630cf", "result_0d174396-5637-5cad-bcc3-be7afcef66e1"]

    static func onlyTropicalAtlantic(_ results: [String]) -> Bool {
        outsideTropicalAtlantic.allSatisfy { rank(of: $0, in: results) == nil }
    }

    /// The app writes UUID-based identifiers in upper case, so compare without case.
    static func rank(of identifier: String, in results: [String]) -> Int? {
        results.firstIndex { $0.lowercased() == identifier.lowercased() }.map { $0 + 1 }
    }

    /// The installed app, addressed by bundle identifier. Xcode 26.5 cannot launch a UI-test
    /// target app on iOS 27 (CoreDeviceError 10004, no process identifier), while a launch by
    /// bundle identifier goes through the device's test daemon and works.
    static func makeApp() -> XCUIApplication {
        XCUIApplication(bundleIdentifier: "com.brycecameron.DiveID")
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIVEID_DEVICE_VALIDATION"] == "1",
                          "device validation runs only on a dedicated physical iPhone")
        continueAfterFailure = false
    }

    // MARK: - Timing

    /// Launch to an enabled Describe action, then Describe to a ready editor, then the first
    /// query, in one process. Run after a fresh install for the cold case, and again for a
    /// later launch: `phase` only labels the record.
    @MainActor
    func testLaunchReadinessAndFirstQuery() {
        let phase = ProcessInfo.processInfo.environment["DIVEID_DEVICE_PHASE"] ?? "unlabelled"
        let app = Self.makeApp()
        let launchStart = Date()
        app.launch()
        let describe = app.buttons["describeAction"]
        let ready = waitUntil { describe.exists && describe.isEnabled && describe.isHittable }
        XCTAssertTrue(ready.met, "Home never offered an enabled Describe action")
        let launchToReady = Date().timeIntervalSince(launchStart)
        let regionVisible = app.staticTexts["Global"].exists
        let describeStart = Date()
        describe.tap()
        let editor = app.textViews["descriptionText"]
        let editorReady = waitUntil { editor.exists && editor.isHittable }
        XCTAssertTrue(editorReady.met)
        let describeToEditor = Date().timeIntervalSince(describeStart)
        XCTAssertTrue(app.staticTexts["Dive region: Global"].exists)
        editor.tap()
        editor.typeText(Self.globalQuery)
        let query = timedSearch(app)
        XCTAssertEqual(query.firstResult, Self.spottedEagleRay)
        report("launch", ["phase": phase, "launchToDescribeEnabledSeconds": launchToReady,
                          "launchPolls": ready.polls, "launchMeanPollSeconds": ready.meanPoll,
                          "describeToEditorSeconds": describeToEditor, "globalShownOnHome": regionVisible,
                          "firstQuerySeconds": query.seconds, "firstQueryPolls": query.polls,
                          "firstQueryMeanPollSeconds": query.meanPoll, "firstQueryMaxPollSeconds": query.maxPoll,
                          "firstResult": query.firstResult ?? "none"])
        attachScreenshot(app, "launch-\(phase)-results")
    }

    /// Twenty searches with the same text in one running process.
    @MainActor
    func testWarmQueryLatency() {
        let app = Self.makeApp()
        app.launch()
        app.buttons["describeAction"].tap()
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(Self.globalQuery)
        let warmup = timedSearch(app)
        XCTAssertEqual(warmup.firstResult, Self.spottedEagleRay)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        var samples: [Double] = []
        for trial in 1...20 {
            XCTAssertTrue(app.buttons["findMatches"].waitForExistence(timeout: 5))
            let query = timedSearch(app)
            XCTAssertEqual(query.firstResult, Self.spottedEagleRay, "trial \(trial)")
            samples.append(query.seconds)
            report("warm", ["trial": trial, "seconds": query.seconds, "polls": query.polls,
                            "meanPollSeconds": query.meanPoll, "maxPollSeconds": query.maxPoll])
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let sorted = samples.sorted()
        let p95 = sorted[Int((0.95 * Double(sorted.count)).rounded(.up)) - 1]
        report("warm-summary", ["n": sorted.count, "medianSeconds": (sorted[9] + sorted[10]) / 2,
                                "p95NearestRankSeconds": p95, "minSeconds": sorted.first!, "maxSeconds": sorted.last!])
    }

    // MARK: - Flows

    /// Positive, region-conflict, ambiguous and no-match descriptions in Tropical Atlantic
    /// Regions, the region offered to Caribbean users; the frozen V05 cases target Caribbean
    /// (V05Development.v2.json), which Release evaluates in Tropical Atlantic Regions.
    @MainActor
    func testCaseKindsInTropicalAtlantic() {
        let app = launch(region: "tropical-atlantic")
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 10))

        let positive = search(app, "Compressed blue reef fish with a yellow spine beside its tail.")
        let tangRank = Self.rank(of: Self.atlanticBlueTang, in: positive.results)
        XCTAssertNotNil(tangRank)
        XCTAssertLessThanOrEqual(tangRank ?? 99, 3, "v05-01-diagnostic allows rank 3 at most")
        XCTAssertTrue(Self.onlyTropicalAtlantic(positive.results), "a species outside the region was shown: \(positive.results)")
        report("case", ["id": "v05-01-diagnostic", "state": positive.state, "results": positive.results,
                        "labels": positive.labels, "expectedRank": tangRank ?? 0])
        attachScreenshot(app, "case-positive")
        goBack(app)

        let conflict = search(app, "Blue and yellow striped surgeonfish on a reef in Fiji.")
        XCTAssertEqual(conflict.state, "failure", "a Fiji description in Tropical Atlantic Regions must be a region mismatch")
        XCTAssertFalse(app.buttons["Try Again"].exists, "a region mismatch is not retryable")
        report("case", ["id": "v05-region-1", "state": conflict.state, "message": conflict.message])
        attachScreenshot(app, "case-region-conflict")
        goBack(app)

        let ambiguous = search(app, "Dark angelfish near a Caribbean reef.")
        XCTAssertTrue(Self.onlyTropicalAtlantic(ambiguous.results))
        for label in ambiguous.labels {
            XCTAssertFalse(label.contains("Strong match") || label.contains("Good match"),
                           "ambiguous case must stay at or below 0.64 confidence: \(label)")
        }
        report("case", ["id": "v05-ambiguous-angelfish", "state": ambiguous.state,
                        "results": ambiguous.results, "labels": ambiguous.labels])
        attachScreenshot(app, "case-ambiguous")
        goBack(app)

        for (id, text) in [("v05-nomatch-vague", "A fish moved past me."),
                           ("v05-nomatch-frog", "A spotted freshwater frog on sand, about 5 cm long.")] {
            let none = search(app, text)
            XCTAssertEqual(none.state, "empty", "\(id) must be the no-match state")
            XCTAssertFalse(resultsState(app, "resultsFailure").exists)
            report("case", ["id": id, "state": none.state, "results": none.results])
            attachScreenshot(app, "case-\(id)")
            goBack(app)
        }
    }

    /// Each of the first three results opens its own species, and going back shows the
    /// same results without searching again.
    @MainActor
    func testResultsOpenTheTappedSpecies() {
        // Start from Global whatever an earlier test left selected.
        let app = launch(region: "global")
        app.buttons["describeAction"].tap()
        let first = search(app, Self.globalQuery)
        XCTAssertGreaterThanOrEqual(first.results.count, 3)
        for identifier in first.results.prefix(3) {
            let card = app.buttons[identifier]
            for _ in 0..<6 where !card.isHittable { app.swipeUp() }
            let cardLabel = card.label
            card.tap()
            let title = app.navigationBars.element(boundBy: 0)
            XCTAssertTrue(title.waitForExistence(timeout: 5))
            let name = title.identifier.isEmpty ? title.label : title.identifier
            XCTAssertTrue(cardLabel.contains(name), "detail '\(name)' does not match card '\(cardLabel)'")
            report("detail", ["result": identifier, "detailTitle": name])
            goBack(app)
            XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 5))
            XCTAssertFalse(resultsState(app, "resultsLoading").exists, "returning re-ran the search")
            XCTAssertEqual(currentResults(app), first.results)
        }
    }

    /// Global search, then a region change to Tropical Atlantic Regions through the UI; its
    /// results hold no species from outside the region, and the choice survives a relaunch.
    @MainActor
    func testRegionSwitchingPersists() {
        // Start from Global whatever an earlier test left selected.
        let app = launch(region: "global")
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Global"].waitForExistence(timeout: 10))
        let global = search(app, Self.globalQuery)
        XCTAssertEqual(global.results.first, Self.spottedEagleRay)
        goBack(app); goBack(app)
        selectRegion(app, "tropical-atlantic")
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 10))
        let regional = search(app, "Compressed blue reef fish with a yellow spine beside its tail.")
        XCTAssertTrue(Self.onlyTropicalAtlantic(regional.results), "\(regional.results)")
        XCTAssertNotNil(Self.rank(of: Self.atlanticBlueTang, in: regional.results))
        report("region", ["globalTop": global.results.first ?? "none", "tropicalAtlanticResults": regional.results])
        app.terminate()
        app.launch()
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 10), "region choice was not kept")
        goBack(app)
        selectRegion(app, "global")
    }

    /// Searches abandoned straight after submission, each followed at once by a different
    /// search: only the newer search's results may appear, and they must stay.
    @MainActor
    func testCancelledSearchCannotReplaceTheNextOne() {
        // Start from Global whatever an earlier test left selected.
        let app = launch(region: "global")
        app.buttons["describeAction"].tap()
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        var observedCancellations = 0
        for trial in 1...10 {
            replaceText(editor, app, Self.globalQuery)
            app.buttons["findMatches"].tap()
            // Leave from the results screen, not from Describe before it has been pushed.
            XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 5))
            let cancelledWhileLoading = resultsState(app, "resultsLoading").exists
            if cancelledWhileLoading { observedCancellations += 1 }
            goBack(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            if trial % 3 == 0 { XCUIDevice.shared.press(.home); app.activate() }
            let newer = search(app, "A spotted freshwater frog on sand, about 5 cm long.")
            XCTAssertEqual(newer.state, "empty", "trial \(trial): the abandoned eagle-ray search replaced the newer one")
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(resultsState(app, "resultsEmpty").exists, "trial \(trial): results changed after settling")
            XCTAssertEqual(currentResults(app), [], "trial \(trial)")
            report("cancel", ["trial": trial, "abandonedWhileLoading": cancelledWhileLoading, "newerState": newer.state])
            goBack(app)
        }
        report("cancel-summary", ["trials": 10, "abandonedWhileLoading": observedCancellations])
    }

    /// Find Matches with the keyboard open as the description grows line by line: the button
    /// must stay hittable and wholly above the keyboard at every length.
    @MainActor
    func testFindMatchesStaysAboveKeyboardAsTextGrows() {
        let app = launch(region: "global")
        app.buttons["describeAction"].tap()
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        let button = app.buttons["findMatches"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let sentence = "Blue and yellow striped surgeonfish on a reef. "
        // First on a freshly opened screen, then after searching and coming back from the results.
        for (pass, steps) in [("first-open", 0...6), ("after-results", 7...10)] {
          if pass == "after-results" {
            button.tap()
            XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 10))
            goBack(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.97)).tap()
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
          }
          for step in steps {
            if step > 0 && step != 7 { editor.typeText(sentence) }
            Thread.sleep(forTimeInterval: 0.5)
            let b = button.frame, k = keyboard.frame
            report("keyboard-layout", ["pass": pass, "step": step, "characters": (editor.value as? String)?.count ?? 0,
                                       "buttonMinY": b.minY, "buttonMaxY": b.maxY, "keyboardMinY": k.minY,
                                       "editorMinY": editor.frame.minY, "editorMaxY": editor.frame.maxY,
                                       "hittable": button.isHittable])
            XCTAssertTrue(button.isHittable, "step \(step): Find Matches is not hittable")
            XCTAssertLessThanOrEqual(b.maxY, k.minY + 0.5, "step \(step): Find Matches overlaps the keyboard")
          }
        }
        attachScreenshot(app, "keyboard-long-text")
    }

    /// Search, go back, edit and search again with the keyboard open, several times: Find Matches
    /// must stay where it first was and a tap on it must open the results every time.
    @MainActor
    func testFindMatchesWorksWithKeyboardAfterReturningFromResults() {
        let app = launch(region: "global")
        app.buttons["describeAction"].tap()
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let button = app.buttons["findMatches"]
        var firstFrame: CGRect?
        for round in 1...5 {
            replaceText(editor, app, round % 2 == 0 ? "Dark angelfish near a reef." : Self.globalQuery)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 0.5)
            let frame = button.frame
            if firstFrame == nil { firstFrame = frame }
            let done = app.buttons["dismissKeyboard"]
            report("keyboard-return", ["round": round, "buttonMinY": frame.minY, "buttonMaxY": frame.maxY,
                                       "keyboardMinY": app.keyboards.firstMatch.frame.minY,
                                       "navigationBarMaxY": app.navigationBars.firstMatch.frame.maxY,
                                       "doneMinY": done.exists ? done.frame.minY : -1,
                                       "editorMinY": editor.frame.minY, "windowHeight": app.windows.firstMatch.frame.height])
            XCTAssertEqual(frame.minY, firstFrame!.minY, accuracy: 1, "round \(round): Find Matches moved")
            button.tap()
            XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 10),
                          "round \(round): tapping Find Matches with the keyboard open did not search")
            goBack(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
        }
    }

    /// Save, terminate, relaunch and reopen; then remove, terminate, relaunch, and it is gone.
    @MainActor
    func testSavedIdentificationSurvivesRelaunchAndRemoval() {
        // Start from Global whatever an earlier test left selected.
        let app = launch(region: "global")
        app.buttons["savedAction"].tap()
        XCTAssertTrue(app.staticTexts["No saved identifications"].waitForExistence(timeout: 5),
                      "the device must start with no saved identifications")
        goBack(app)
        app.buttons["describeAction"].tap()
        let found = search(app, Self.globalQuery)
        XCTAssertEqual(found.results.first, Self.spottedEagleRay)
        app.buttons[Self.spottedEagleRay].tap()
        XCTAssertTrue(app.navigationBars["Spotted Eagle Ray"].waitForExistence(timeout: 5))
        let toggle = app.buttons["toggleSaved"]
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        let before = toggle.label
        toggle.tap()
        XCTAssertTrue(waitUntil { toggle.label != before }.met, "save did not change the button")
        report("save", ["toggleBefore": before, "toggleAfter": toggle.label])

        app.terminate()
        app.launch()
        app.buttons["savedAction"].tap()
        let row = app.buttons.containing(.staticText, identifier: "Spotted Eagle Ray").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "save did not survive relaunch")
        // The row shows the match explanation; the description is checked on the reopened save.
        report("saved-after-relaunch", ["row": row.label])
        row.tap()
        XCTAssertTrue(app.navigationBars["Spotted Eagle Ray"].waitForExistence(timeout: 5))
        // Both sections sit below the fold on a phone, so scroll until each appears.
        XCTAssertTrue(revealText(app, Self.globalQuery), "reopened save does not show its description")
        // The region is in the collapsed "Habitat and range" group.
        XCTAssertTrue(revealText(app, "Habitat and range"), "reopened save has no habitat and range group")
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Habitat and range'")).firstMatch.tap()
        XCTAssertTrue(revealText(app, "Global"), "reopened save does not show its region")
        let reopened = app.staticTexts.allElementsBoundByIndex.map(\.label)
        report("saved-reopened", ["texts": Array(reopened.prefix(30))])
        attachScreenshot(app, "saved-reopened")
        let removeToggle = app.buttons["toggleSaved"]
        for _ in 0..<6 where !removeToggle.isHittable { app.swipeDown() }
        for _ in 0..<6 where !removeToggle.isHittable { app.swipeUp() }
        removeToggle.tap()
        let dialog = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Remove'")).firstMatch
        if dialog.waitForExistence(timeout: 2) { dialog.tap() }

        app.terminate()
        app.launch()
        app.buttons["savedAction"].tap()
        XCTAssertTrue(app.staticTexts["No saved identifications"].waitForExistence(timeout: 5), "removal did not survive relaunch")
        report("removed-after-relaunch", ["empty": true])
    }

    /// Debug build with the real Semantic-global artifacts bundled, launched with the experimental
    /// flag: each search must report Core ML semantic as both requested and actual engine. Kept
    /// apart from the Release rows; Release never offers semantic search.
    @MainActor
    func testExperimentalSemanticOnDebugBuild() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIVEID_DEVICE_PHASE"] == "experimental-semantic",
                          "needs a Debug build with Semantic-global bundled")
        let app = Self.makeApp()
        app.launchArguments = ["-DiveIDExperimentalSemanticSearch", "YES"]
        app.launch()
        selectRegion(app, "global")
        app.buttons["describeAction"].tap()
        for (id, text) in [("positive", Self.globalQuery), ("ambiguous", "Dark angelfish near a reef."),
                           ("no-match", "A spotted freshwater frog on sand, about 5 cm long.")] {
            let outcome = search(app, text)
            let lines = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Requested engine' OR label BEGINSWITH 'Actual engine' OR label BEGINSWITH 'Fallback'"))
                .allElementsBoundByIndex.map { $0.label }
            report("semantic-device", ["case": id, "state": outcome.state, "results": outcome.results, "diagnostics": lines])
            XCTAssertTrue(lines.contains("Requested engine: Core ML semantic + BM25"), "\(id): \(lines)")
            XCTAssertTrue(lines.contains("Actual engine: Core ML semantic + BM25"), "\(id): \(lines)")
            XCTAssertFalse(lines.contains { $0.hasPrefix("Fallback") }, "\(id): \(lines)")
            attachScreenshot(app, "semantic-\(id)")
            goBack(app)
        }
    }

    /// After the previous build stored Caribbean (retired 2026-10-26), this build reports the
    /// region unavailable, offers Tropical Atlantic Regions without switching, and keeps the
    /// choice after a relaunch.
    @MainActor
    func testRecoveryFromRetiredSelectedRegion() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIVEID_DEVICE_PHASE"] == "after-previous-build-caribbean",
                          "needs the previous-build installation step first")
        let app = Self.makeApp()
        app.launch()
        XCTAssertTrue(app.staticTexts["Dive region unavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["describeAction"].isEnabled, "no region was substituted")
        let suggestion = app.buttons["useSuggestedRegionAction"]
        XCTAssertTrue(suggestion.exists)
        XCTAssertTrue(suggestion.label.contains("Tropical Atlantic Regions"), suggestion.label)
        attachScreenshot(app, "region-retired")
        suggestion.tap()
        XCTAssertTrue(waitUntil(timeout: 10) { app.buttons["describeAction"].isEnabled }.met)
        app.terminate()
        app.launch()
        XCTAssertFalse(app.staticTexts["Dive region unavailable"].waitForExistence(timeout: 3))
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 10))
        report("retired-region", ["recoveredTo": "tropical-atlantic", "persisted": true])
        goBack(app)
        selectRegion(app, "global")
    }

    /// The setup half of the step above, run against the previous build (which still offers
    /// Caribbean): choose Caribbean, then this build is installed over it without deleting the container.
    @MainActor
    func testSelectCaribbeanInPreviousBuild() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIVEID_DEVICE_PHASE"] == "previous-build-select-caribbean")
        let app = Self.makeApp()
        app.launch()
        selectRegion(app, "caribbean")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Caribbean'")).firstMatch.waitForExistence(timeout: 5),
                      "Caribbean was not selected")
        Thread.sleep(forTimeInterval: 1)
        app.terminate()
    }

    // MARK: - Helpers

    private struct Poll { let met: Bool; let polls: Int; let meanPoll: Double; let maxPoll: Double }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) -> Poll {
        let start = Date()
        var last = start, polls = 0, maxPoll = 0.0
        while Date().timeIntervalSince(start) < timeout {
            let met = condition()
            let now = Date()
            polls += 1; maxPoll = max(maxPoll, now.timeIntervalSince(last)); last = now
            if met { return Poll(met: true, polls: polls, meanPoll: now.timeIntervalSince(start) / Double(polls), maxPoll: maxPoll) }
        }
        return Poll(met: false, polls: polls, meanPoll: timeout / Double(max(polls, 1)), maxPoll: maxPoll)
    }

    private struct Timed { let seconds: Double; let polls: Int; let meanPoll: Double; let maxPoll: Double; let firstResult: String? }

    /// Taps Find Matches and times it to the first snapshot with results, the empty state or a failure.
    @MainActor
    private func timedSearch(_ app: XCUIApplication) -> Timed {
        let anyResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).firstMatch
        let start = Date()
        app.buttons["findMatches"].tap()
        let done = waitUntil { anyResult.exists || resultsState(app, "resultsEmpty").exists || resultsState(app, "resultsFailure").exists }
        let seconds = Date().timeIntervalSince(start)
        XCTAssertTrue(done.met, "search never finished")
        return Timed(seconds: seconds, polls: done.polls, meanPoll: done.meanPoll, maxPoll: done.maxPoll,
                     firstResult: anyResult.exists ? anyResult.identifier : nil)
    }

    private struct Outcome { let state: String; let results: [String]; let labels: [String]; let message: String }

    @MainActor
    private func search(_ app: XCUIApplication, _ text: String) -> Outcome {
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        replaceText(editor, app, text)
        let timed = timedSearch(app)
        let results = currentResults(app)
        let labels = results.map { app.buttons[$0].label }
        let state = !results.isEmpty ? "results" : resultsState(app, "resultsEmpty").exists ? "empty" : "failure"
        let message = resultsState(app, "resultsFailure").exists ? stateText(app, "resultsFailure") : ""
        report("search", ["text": text, "state": state, "seconds": timed.seconds, "count": results.count])
        return Outcome(state: state, results: results, labels: labels, message: message)
    }

    /// Results states are ContentUnavailableView or a loading view, whose identifier lands
    /// on their texts and images rather than on one "other" element, so match any type.
    @MainActor
    private func resultsState(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func stateText(_ app: XCUIApplication, _ identifier: String) -> String {
        app.staticTexts.matching(identifier: identifier).allElementsBoundByIndex.map { $0.label }.joined(separator: " ")
    }

    @MainActor
    private func revealText(_ app: XCUIApplication, _ text: String) -> Bool {
        let match = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        for _ in 0..<8 where !match.exists { app.swipeUp() }
        return match.exists
    }

    @MainActor
    private func currentResults(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).allElementsBoundByIndex.map(\.identifier)
    }

    @MainActor
    private func replaceText(_ editor: XCUIElement, _ app: XCUIApplication, _ text: String) {
        editor.tap()
        // A tap can leave the cursor mid-text. The editor's lower part can sit under the keyboard,
        // so put the cursor at the end of the first line and delete, until nothing is left.
        let firstLineEnd = editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: editor.frame.width - 12, dy: 22))
        for _ in 0..<12 {
            guard let current = editor.value as? String, !current.isEmpty else { break }
            firstLineEnd.tap()
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5))
        }
        XCTAssertEqual(editor.value as? String ?? "", "", "the editor could not be cleared")
        editor.typeText(text)
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    @MainActor
    private func launch(region: String) -> XCUIApplication {
        let app = Self.makeApp()
        app.launch()
        selectRegion(app, region)
        return app
    }

    /// Opens region selection from Home and picks a region through the UI, so the choice is persisted.
    @MainActor
    private func selectRegion(_ app: XCUIApplication, _ id: String) {
        let change = app.buttons["changeRegionAction"].exists ? app.buttons["changeRegionAction"] : app.buttons["offlinePackSummary"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        change.tap()
        let row = app.buttons["region_\(id)"]
        var swiped = false
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp(); swiped = true }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "region \(id) not offered")
        // Let the list stop moving, or the tap can land on a neighbouring row.
        if swiped { Thread.sleep(forTimeInterval: 1) }
        row.tap()
        XCTAssertTrue(waitUntil(timeout: 5) { app.buttons["describeAction"].exists || app.buttons.matching(identifier: "region_\(id)").matching(NSPredicate(format: "selected == true")).count > 0 }.met)
        if app.navigationBars.buttons.element(boundBy: 0).exists && !app.buttons["describeAction"].exists { goBack(app) }
        XCTAssertTrue(app.buttons["describeAction"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        // The whole screen, so the status bar records the radio state.
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(name).png"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func report(_ kind: String, _ fields: [String: Any]) {
        var record = fields
        record["kind"] = kind
        record["test"] = name
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print("DEVICEVAL \(line)")
        }
    }
}
