import XCTest

/// Dive Log: create a dive → save a sighting from search into it → export it.
/// Starts from an empty log (-resetDiveLogForUITests, Debug only), in metres.
final class DiveLogUITests: XCTestCase {
    private let eagleRay = "result_00000000-0000-0000-0000-000000000010"

    @MainActor
    func testCreateDiveSaveSightingIntoItAndExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic", "-resetDiveLogForUITests", "-diveLogDepthUnit", "metres"]
        app.launch()

        // Create a dive.
        tap(app, app.buttons["savedAction"])
        XCTAssertTrue(app.navigationBars["Dive Log"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No saved identifications"].exists, "starts empty")
        tap(app, app.buttons["addDive"])
        let site = app.textFields["diveSite"]
        tap(app, site)
        site.typeText("UITest Reef")
        let depth = app.textFields["diveDepth"]
        tap(app, depth)
        depth.typeText("18")
        tap(app, app.buttons["saveDive"])
        let diveRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dive_'")).firstMatch
        XCTAssertTrue(diveRow.waitForExistence(timeout: 5))
        XCTAssertTrue(diveRow.label.contains("UITest Reef") && diveRow.label.contains("max 18 m"), diveRow.label)

        // Save a sighting from search into today's dive.
        goHome(app)
        tap(app, app.buttons["describeAction"])
        let editor = app.textViews["descriptionText"]
        tap(app, editor)
        editor.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        app.buttons["findMatches"].tap()
        tap(app, app.buttons[eagleRay])
        tap(app, app.buttons["toggleSaved"])
        let today = app.buttons["Add to Today's Dive (UITest Reef)"].firstMatch  // the dialog can expose it twice
        XCTAssertTrue(today.waitForExistence(timeout: 5), "Add to dive offers today's dive")
        XCTAssertTrue(app.buttons["Skip"].exists, "Skip is one tap away")
        today.tap()
        XCTAssertTrue(today.waitForNonExistence(timeout: 5))

        // The dive now holds the sighting; export it.
        goHome(app)
        tap(app, app.buttons["savedAction"])
        tap(app, diveRow)
        let sightings = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sighting_'"))
        XCTAssertTrue(sightings.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(sightings.count, 1)
        tap(app, app.buttons["exportDive"])
        let count = app.staticTexts["exportRowCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "1 sighting in 1 dive")
        XCTAssertTrue(app.buttons["exportShare"].waitForExistence(timeout: 5) || app.descendants(matching: .any)["exportShare"].exists,
                      "the share sheet opens only from the preview")
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// Edit a sighting: move it to another dive with new depth and notes, check both dives,
    /// relaunch, then clear the depth and dive, and check Cancel saves nothing.
    @MainActor
    func testEditSightingReassignRelaunchClearAndCancel() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic", "-resetDiveLogForUITests", "-diveLogDepthUnit", "metres"]
        app.launch()

        // Dive A, then a sighting saved into it, then dive B.
        tap(app, app.buttons["savedAction"])
        createDive(app, site: "Dive A UITest")
        goHome(app)
        tap(app, app.buttons["describeAction"])
        let description = app.textViews["descriptionText"]
        tap(app, description)
        description.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        app.buttons["findMatches"].tap()
        tap(app, app.buttons[eagleRay])
        tap(app, app.buttons["toggleSaved"])
        let today = app.buttons["Add to Today's Dive (Dive A UITest)"].firstMatch
        XCTAssertTrue(today.waitForExistence(timeout: 5))
        today.tap()
        XCTAssertTrue(today.waitForNonExistence(timeout: 5))
        goHome(app)
        tap(app, app.buttons["savedAction"])
        createDive(app, site: "Dive B UITest")

        // Open the sighting from dive A and edit it.
        tap(app, diveRow(app, "Dive A UITest"))
        tap(app, app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sighting_'")).firstMatch)
        assertValue(app, "sightingDiveValue", contains: "Dive A UITest")
        assertValue(app, "sightingDepthValue", contains: "Not recorded")
        tap(app, app.buttons["editSighting"])
        XCTAssertTrue(app.navigationBars["Edit Sighting"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.dynamicType, .sufficientElementDescription]) { issue in
            let identifier = issue.element?.identifier ?? ""
            // Only this form is checked; the page behind the sheet is not part of this change.
            let mine = identifier.hasPrefix("sighting") || identifier.hasSuffix("SightingEdit")
            // Save and Cancel are system navigation-bar buttons: iOS keeps them at a fixed size and
            // shows them in the Large Content Viewer instead (the dive form's are the same).
            let systemBarButton = issue.auditType == .dynamicType && ["saveSightingEdit", "cancelSightingEdit"].contains(identifier)
            return !mine || systemBarButton
        }
        let depth = app.textFields["sightingDepth"]
        tap(app, depth)
        depth.typeText("deep")
        XCTAssertTrue(app.staticTexts["sightingDepthError"].waitForExistence(timeout: 5), "bad depth is explained")
        XCTAssertFalse(app.buttons["saveSightingEdit"].isEnabled)
        depth.clearText()
        depth.typeText("12.5")
        let notes = app.textFields["sightingNotes"]
        tap(app, notes)
        notes.typeText("Edited in UI test")
        tap(app, app.buttons["sightingDive"])
        tap(app, app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dive B UITest'")).firstMatch)
        tap(app, app.buttons["saveSightingEdit"])
        XCTAssertTrue(app.navigationBars["Edit Sighting"].waitForNonExistence(timeout: 5))
        assertValue(app, "sightingDiveValue", contains: "Dive B UITest")
        assertValue(app, "sightingDepthValue", contains: "12.5 m")
        assertValue(app, "sightingNotesValue", contains: "Edited in UI test")

        // Back on dive A: the sighting has moved out; dive B has it.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["0 sightings"].waitForExistence(timeout: 5), "dive A refreshed")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(diveRow(app, "Dive B UITest").label.contains("1 sighting"), diveRow(app, "Dive B UITest").label)
        XCTAssertTrue(diveRow(app, "Dive A UITest").label.contains("0 sightings"), diveRow(app, "Dive A UITest").label)

        // Relaunch on the same store: the edit is still there.
        app.terminate()
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic", "-keepDiveLogForUITests", "-diveLogDepthUnit", "metres"]
        app.launch()
        tap(app, app.buttons["savedAction"])
        tap(app, diveRow(app, "Dive B UITest"))
        tap(app, app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sighting_'")).firstMatch)
        assertValue(app, "sightingDepthValue", contains: "12.5 m")
        assertValue(app, "sightingNotesValue", contains: "Edited in UI test")

        // Clear the depth and the dive.
        tap(app, app.buttons["editSighting"])
        tap(app, app.buttons["clearSightingDepth"])
        tap(app, app.buttons["sightingDive"])
        tap(app, app.buttons["No dive"].firstMatch)
        tap(app, app.buttons["saveSightingEdit"])
        XCTAssertTrue(app.navigationBars["Edit Sighting"].waitForNonExistence(timeout: 5))
        assertValue(app, "sightingDepthValue", contains: "Not recorded")
        assertValue(app, "sightingDiveValue", contains: "No dive")

        // Cancel saves nothing.
        tap(app, app.buttons["editSighting"])
        let notesAgain = app.textFields["sightingNotes"]
        tap(app, notesAgain)
        notesAgain.typeText(" and more")
        tap(app, app.buttons["cancelSightingEdit"])
        XCTAssertTrue(app.navigationBars["Edit Sighting"].waitForNonExistence(timeout: 5))
        assertValue(app, "sightingNotesValue", contains: "Edited in UI test")
        XCTAssertFalse(app.descendants(matching: .any)["sightingNotesValue"].firstMatch.label.contains("and more"))
    }

    // MARK: Helpers

    @MainActor
    private func createDive(_ app: XCUIApplication, site: String) {
        XCTAssertTrue(app.navigationBars["Dive Log"].waitForExistence(timeout: 5))
        tap(app, app.buttons["addDive"])
        let field = app.textFields["diveSite"]
        tap(app, field)
        field.typeText(site)
        tap(app, app.buttons["saveDive"])
        XCTAssertTrue(diveRow(app, site).waitForExistence(timeout: 5))
    }

    @MainActor
    private func diveRow(_ app: XCUIApplication, _ site: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dive_' AND label CONTAINS %@", site)).firstMatch
    }

    @MainActor
    private func assertValue(_ app: XCUIApplication, _ identifier: String, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) missing", file: file, line: line)
        let shown = [element.label, element.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(shown.contains(text), "\(identifier): \(shown)", file: file, line: line)
    }

    @MainActor
    private func goHome(_ app: XCUIApplication) {
        for _ in 0..<5 where !app.buttons["describeAction"].exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 2) else { break }
            back.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        XCTAssertTrue(app.buttons["describeAction"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) missing")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        _ = XCTWaiter().wait(for: [enabled], timeout: 10)
        for _ in 0..<8 where !element.isHittable { app.swipeUp(velocity: .slow) }
        var frame = element.frame
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            if element.frame == frame { break }
            frame = element.frame
        }
        element.tap()
    }
}

private extension XCUIElement {
    func clearText() {
        guard let current = value as? String, !current.isEmpty else { return }
        typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
}
