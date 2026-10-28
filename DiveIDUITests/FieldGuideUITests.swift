import XCTest

/// Field guide: group → species → detail, the region filter (remembered), and the name filter.
final class FieldGuideUITests: XCTestCase {
    private let queenAngelfish = "FC213EFF-6BA6-53AB-B288-F6E654299E68"  // UUIDs print in upper case

    @MainActor
    func testGroupToSpeciesToDetailAndSaveWithoutAMatch() {
        let app = openGuide()
        tap(app, app.buttons["fieldGuideGroup_shark"])
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fieldGuideSpecies_'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.hasSuffix(", photo") || first.label.hasSuffix(", illustration"), "VoiceOver says photo or illustration: \(first.label)")
        tap(app, first)
        let save = app.buttons["toggleSaved"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "the existing species page, with Save")
        tap(app, save)
        XCTAssertTrue(app.buttons["Remove from Saved Identifications"].waitForExistence(timeout: 5), "saving works with no match")
        tap(app, app.buttons["Remove from Saved Identifications"])  // leave nothing behind
    }

    @MainActor
    func testRegionFilterChangesTheCountsShowsTheNoteAndIsRemembered() {
        var app = openGuide()
        let count = app.staticTexts["fieldGuideRegionCount"]
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        chooseRegion(app, "All regions")
        let allCount = count.label
        chooseRegion(app, "Mediterranean and Black Sea")
        XCTAssertTrue(app.descendants(matching: .any)["fieldGuideUnknownNote"].waitForExistence(timeout: 5),
                      "unknown distribution is explained, not hidden")
        XCTAssertNotEqual(count.label, allCount)
        let mediterraneanCount = count.label

        app.terminate()
        app = openGuide()
        XCTAssertTrue(app.staticTexts["fieldGuideRegionCount"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["fieldGuideRegionCount"].label, mediterraneanCount, "the last region is remembered")
        chooseRegion(app, "All regions")
        XCTAssertFalse(app.descendants(matching: .any)["fieldGuideUnknownNote"].exists)
    }

    @MainActor
    func testNameFilterFindsASpeciesByScientificName() {
        let app = openGuide()
        chooseRegion(app, "All regions")
        tap(app, app.buttons["fieldGuideGroup_fish"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fieldGuideSpecies_'")).firstMatch.waitForExistence(timeout: 10))
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: 3) { app.swipeDown(velocity: .slow) }
        tap(app, field)
        field.typeText("Holacanthus ciliaris")
        let row = app.buttons["fieldGuideSpecies_\(queenAngelfish)"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Queen Angelfish") && row.label.hasSuffix("photo"), row.label)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'fieldGuideSpecies_'")).count, 1)
    }

    // MARK: Helpers

    @MainActor
    private func openGuide() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        let entry = app.buttons["fieldGuideAction"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        tap(app, entry)
        XCTAssertTrue(app.navigationBars["Field Guide"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func chooseRegion(_ app: XCUIApplication, _ title: String) {
        let picker = app.buttons["fieldGuideRegion"]
        tap(app, picker)
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), title)
        option.tap()
        XCTAssertTrue(option.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) missing")
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
