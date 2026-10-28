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

    // MARK: Helpers

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
