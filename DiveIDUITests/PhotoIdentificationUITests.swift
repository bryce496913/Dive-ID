import XCTest

/// Photo identification in a Debug build, with the test recognizer: choose a photo → results →
/// detail → save into a new dive. Uses a generated test photo (-uiTestingSamplePhoto, Debug
/// only) instead of the system photo picker.
final class PhotoIdentificationUITests: XCTestCase {
    @MainActor
    func testChoosePhotoSeeResultsOpenDetailAndSave() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic", "-uiTestingSamplePhoto",
                               "-resetDiveLogForUITests", "-resetFeedbackForUITests", "-diveLogDepthUnit", "metres"]
        app.launch()

        let photo = app.buttons["photoAction"]
        for _ in 0..<4 where !photo.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(photo.isEnabled, "photo identification is on in Debug")
        tap(app, photo)
        XCTAssertTrue(app.navigationBars["Identify From Photo"].waitForExistence(timeout: 5))
        tap(app, app.buttons["useTestPhoto"])
        let identify = app.buttons["identifyPhoto"]
        XCTAssertTrue(identify.waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "isEnabled == true").evaluate(with: identify) || waitEnabled(identify), "the test photo is prepared")
        tap(app, identify)

        XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 10))
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10), "the test recognizer suggests species")
        XCTAssertTrue(app.descendants(matching: .any)["photoPlaceholderWarning"].exists, "placeholder results are labelled")
        let coverage = app.staticTexts["photoCoverage"]
        for _ in 0..<6 where !coverage.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(coverage.label.hasPrefix("Photo matching covers "), coverage.label)
        XCTAssertTrue(app.buttons["describeInstead"].exists)
        for _ in 0..<6 where !firstResult.isHittable { app.swipeDown(velocity: .slow) }
        let speciesName = firstResult.label
        tap(app, firstResult)

        let save = app.buttons["toggleSaved"]
        tap(app, save)
        let newDive = app.buttons["newDiveForSighting"].firstMatch
        XCTAssertTrue(newDive.waitForExistence(timeout: 5), "Add to dive is offered for a photo result")
        newDive.tap()
        let site = app.textFields["diveSite"]
        tap(app, site)
        site.typeText("Photo Reef")
        tap(app, app.buttons["saveDive"])
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(NSPredicate(format: "label CONTAINS 'Remove'").evaluate(with: save) || save.label.contains("Remove"),
                      "saved: \(save.label) for \(speciesName)")

        // The dive now holds the photo sighting.
        for _ in 0..<5 where !app.buttons["savedAction"].exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.waitForExistence(timeout: 2) else { break }
            back.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        tap(app, app.buttons["savedAction"])
        let diveRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'dive_'")).firstMatch
        XCTAssertTrue(diveRow.waitForExistence(timeout: 5))
        XCTAssertTrue(diveRow.label.contains("Photo Reef"), diveRow.label)
        tap(app, diveRow)
        let sightings = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'sighting_'"))
        XCTAssertTrue(sightings.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(sightings.count, 1)
    }

    /// Release behaviour, simulated in Debug: the photo card is disabled and says "Coming later".
    @MainActor
    func testPhotoCardIsComingLaterWhenDisabled() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-photoIdentificationDisabled"]
        app.launch()
        let photo = app.buttons["photoAction"]
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        XCTAssertFalse(photo.isEnabled)
        XCTAssertTrue(app.staticTexts["Coming later"].exists)
    }

    // MARK: Helpers

    @MainActor
    private func waitEnabled(_ element: XCUIElement) -> Bool {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        return XCTWaiter().wait(for: [enabled], timeout: 10) == .completed
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) missing")
        _ = waitEnabled(element)
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
