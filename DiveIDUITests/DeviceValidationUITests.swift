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
    static let caribbeanApproved: Set<String> = [atlanticBlueTang, "result_fc213eff-6ba6-53ab-b288-f6e654299e68"]

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
        let app = XCUIApplication()
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
        let app = XCUIApplication()
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

    /// Positive, region-conflict, ambiguous and no-match descriptions in Caribbean, whose
    /// frozen cases target it (V05Development.v2.json).
    @MainActor
    func testCaseKindsInCaribbean() {
        let app = launch(region: "caribbean")
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Caribbean"].waitForExistence(timeout: 10))

        let positive = search(app, "Compressed blue reef fish with a yellow spine beside its tail.")
        let tangRank = positive.results.firstIndex(of: Self.atlanticBlueTang).map { $0 + 1 }
        XCTAssertNotNil(tangRank)
        XCTAssertLessThanOrEqual(tangRank ?? 99, 3, "v05-01-diagnostic allows rank 3 at most")
        XCTAssertTrue(Set(positive.results).isSubset(of: Self.caribbeanApproved), "a draft was searchable: \(positive.results)")
        report("case", ["id": "v05-01-diagnostic", "state": positive.state, "results": positive.results,
                        "labels": positive.labels, "expectedRank": tangRank ?? 0])
        attachScreenshot(app, "case-positive")
        goBack(app)

        let conflict = search(app, "Blue and yellow striped surgeonfish on a reef in Fiji.")
        XCTAssertEqual(conflict.state, "failure", "a Fiji description in Caribbean must be a region mismatch")
        XCTAssertFalse(app.buttons["Try Again"].exists, "a region mismatch is not retryable")
        report("case", ["id": "v05-region-1", "state": conflict.state, "message": conflict.message])
        attachScreenshot(app, "case-region-conflict")
        goBack(app)

        let ambiguous = search(app, "Dark angelfish near a Caribbean reef.")
        XCTAssertTrue(Set(ambiguous.results).isSubset(of: Self.caribbeanApproved))
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
            XCTAssertFalse(app.otherElements["resultsFailure"].exists)
            report("case", ["id": id, "state": none.state, "results": none.results])
            attachScreenshot(app, "case-\(id)")
            goBack(app)
        }
    }

    /// Each of the first three results opens its own species, and going back shows the
    /// same results without searching again.
    @MainActor
    func testResultsOpenTheTappedSpecies() {
        let app = XCUIApplication()
        app.launch()
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
            XCTAssertFalse(app.otherElements["resultsLoading"].exists, "returning re-ran the search")
            XCTAssertEqual(currentResults(app), first.results)
        }
    }

    /// Global search, then a region change to Caribbean through the UI; Caribbean results
    /// hold only its approved species, and the choice survives a relaunch.
    @MainActor
    func testRegionSwitchingPersists() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Global"].waitForExistence(timeout: 10))
        let global = search(app, Self.globalQuery)
        XCTAssertEqual(global.results.first, Self.spottedEagleRay)
        goBack(app); goBack(app)
        selectRegion(app, "caribbean")
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Caribbean"].waitForExistence(timeout: 10))
        let caribbean = search(app, "Compressed blue reef fish with a yellow spine beside its tail.")
        XCTAssertTrue(Set(caribbean.results).isSubset(of: Self.caribbeanApproved), "\(caribbean.results)")
        report("region", ["globalTop": global.results.first ?? "none", "caribbeanResults": caribbean.results])
        app.terminate()
        app.launch()
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Caribbean"].waitForExistence(timeout: 10), "region choice was not kept")
        goBack(app)
        selectRegion(app, "global")
    }

    /// Searches abandoned straight after submission, each followed at once by a different
    /// search: only the newer search's results may appear, and they must stay.
    @MainActor
    func testCancelledSearchCannotReplaceTheNextOne() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["describeAction"].tap()
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        var observedCancellations = 0
        for trial in 1...10 {
            replaceText(editor, app, Self.globalQuery)
            app.buttons["findMatches"].tap()
            let cancelledWhileLoading = app.otherElements["resultsLoading"].exists
            if cancelledWhileLoading { observedCancellations += 1 }
            goBack(app)
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            if trial % 3 == 0 { XCUIDevice.shared.press(.home); app.activate() }
            let newer = search(app, "A spotted freshwater frog on sand, about 5 cm long.")
            XCTAssertEqual(newer.state, "empty", "trial \(trial): the abandoned eagle-ray search replaced the newer one")
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(app.otherElements["resultsEmpty"].exists, "trial \(trial): results changed after settling")
            XCTAssertEqual(currentResults(app), [], "trial \(trial)")
            report("cancel", ["trial": trial, "abandonedWhileLoading": cancelledWhileLoading, "newerState": newer.state])
            goBack(app)
        }
        report("cancel-summary", ["trials": 10, "abandonedWhileLoading": observedCancellations])
    }

    /// Save, terminate, relaunch and reopen; then remove, terminate, relaunch, and it is gone.
    @MainActor
    func testSavedIdentificationSurvivesRelaunchAndRemoval() {
        let app = XCUIApplication()
        app.launch()
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
        XCTAssertTrue(row.label.contains(Self.globalQuery) || app.staticTexts[Self.globalQuery].exists,
                      "saved row lost the description: \(row.label)")
        report("saved-after-relaunch", ["row": row.label])
        row.tap()
        XCTAssertTrue(app.navigationBars["Spotted Eagle Ray"].waitForExistence(timeout: 5))
        let reopened = app.staticTexts.allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(reopened.contains { $0.contains("Global") }, "reopened save does not show its region")
        XCTAssertTrue(reopened.contains { $0.contains(Self.globalQuery) }, "reopened save does not show its description")
        report("saved-reopened", ["texts": Array(reopened.prefix(30))])
        attachScreenshot(app, "saved-reopened")
        let removeToggle = app.buttons["toggleSaved"]
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

    /// After a Debug install selected Tropical Pacific, the Release update reports the region
    /// unavailable, offers the approved regions, and keeps the new choice after a relaunch.
    @MainActor
    func testRecoveryFromUnavailableSelectedRegion() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIVEID_DEVICE_PHASE"] == "after-debug-tropical-pacific",
                          "needs the Debug installation step first")
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Dive region unavailable"].waitForExistence(timeout: 10))
        attachScreenshot(app, "region-unavailable")
        selectRegion(app, "global")
        app.terminate()
        app.launch()
        XCTAssertFalse(app.staticTexts["Dive region unavailable"].waitForExistence(timeout: 3))
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Global"].waitForExistence(timeout: 10))
        report("unavailable-region", ["recoveredTo": "global", "persisted": true])
    }

    /// The Debug half of the step above: choose Tropical Pacific, then the Release build is
    /// installed over it without deleting the container.
    @MainActor
    func testSelectTropicalPacificInDebug() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DIVEID_DEVICE_PHASE"] == "debug-select-tropical-pacific")
        let app = XCUIApplication()
        app.launch()
        selectRegion(app, "tropical-pacific")
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
        let done = waitUntil { anyResult.exists || app.otherElements["resultsEmpty"].exists || app.otherElements["resultsFailure"].exists }
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
        let state = !results.isEmpty ? "results" : app.otherElements["resultsEmpty"].exists ? "empty" : "failure"
        let message = app.otherElements["resultsFailure"].exists ? app.otherElements["resultsFailure"].label : ""
        report("search", ["text": text, "state": state, "seconds": timed.seconds, "count": results.count])
        return Outcome(state: state, results: results, labels: labels, message: message)
    }

    @MainActor
    private func currentResults(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).allElementsBoundByIndex.map(\.identifier)
    }

    @MainActor
    private func replaceText(_ editor: XCUIElement, _ app: XCUIApplication, _ text: String) {
        editor.tap()
        if let current = editor.value as? String, !current.isEmpty {
            editor.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5))
        }
        editor.typeText(text)
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    @MainActor
    private func launch(region: String) -> XCUIApplication {
        let app = XCUIApplication()
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
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "region \(id) not offered")
        row.tap()
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
