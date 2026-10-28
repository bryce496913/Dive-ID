import XCTest

/// "Was this right?": one test per answer path, each from a fresh install's feedback state
/// (-resetFeedbackForUITests, Debug only), so the consent sheet appears first.
final class FeedbackUITests: XCTestCase {
    private let eagleRay = "00000000-0000-0000-0000-000000000010"

    @MainActor
    func testYesThisOnePicksAMatchThenSaves() {
        let app = searchForEagleRay()
        tap(app, app.buttons["feedbackYes"])
        tap(app, app.buttons["feedbackPick_\(eagleRay)"])
        consentAndSave(app, evaluation: true)
        XCTAssertTrue(app.staticTexts["feedbackSaved"].waitForExistence(timeout: 5) || app.otherElements["feedbackSaved"].exists
                      || app.descendants(matching: .any)["feedbackSaved"].exists)
    }

    @MainActor
    func testNoneOfTheseSaves() {
        let app = searchForEagleRay()
        tap(app, app.buttons["feedbackNone"])
        consentAndSave(app, evaluation: false)
        XCTAssertTrue(app.descendants(matching: .any)["feedbackSaved"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNotSureSavesAndSharePreviewCountsOnlyConsentedRecords() {
        let app = searchForEagleRay()
        tap(app, app.buttons["feedbackNotSure"])
        consentAndSave(app, evaluation: true)
        XCTAssertTrue(app.descendants(matching: .any)["feedbackSaved"].waitForExistence(timeout: 5))
        // Credits: one saved, one shareable; the preview shows the count before any share sheet.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tap(app, app.buttons["creditsAction"])
        XCTAssertTrue(app.staticTexts["1 saved, 1 can be shared"].waitForExistence(timeout: 5))
        tap(app, app.buttons["shareFeedback"])
        XCTAssertTrue(app.staticTexts["exportCount"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["exportCount"].label.hasPrefix("1 record will be shared"))
    }

    @MainActor
    func testThisIsWhatISawOnTheSpeciesPage() {
        let app = searchForEagleRay()
        for _ in 0..<4 where !app.buttons["result_\(eagleRay)"].isHittable { app.swipeDown(velocity: .slow) }
        tap(app, app.buttons["result_\(eagleRay)"])
        XCTAssertTrue(app.buttons["toggleSaved"].waitForExistence(timeout: 5), "Save Identification is unchanged")
        tap(app, app.buttons["feedbackThisIsWhatISaw"])
        consentAndSave(app, evaluation: false)
        XCTAssertTrue(app.descendants(matching: .any)["feedbackSaved"].waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    @MainActor
    private func searchForEagleRay() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic", "-resetFeedbackForUITests"]
        app.launch()
        tap(app, app.buttons["describeAction"])
        let editor = app.textViews["descriptionText"]
        tap(app, editor)
        editor.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        app.buttons["findMatches"].tap()
        XCTAssertTrue(app.buttons["result_\(eagleRay)"].waitForExistence(timeout: 10))
        let prompt = app.descendants(matching: .any)["feedbackPrompt"]
        for _ in 0..<12 where !app.buttons["feedbackNotSure"].isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(prompt.exists)
        return app
    }

    @MainActor
    private func consentAndSave(_ app: XCUIApplication, evaluation: Bool) {
        let continueButton = app.buttons["consentContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5), "consent comes before the first save")
        let evaluationToggle = app.switches["consentEvaluation"]
        XCTAssertEqual(evaluationToggle.value as? String, "0", "consent starts off")
        if evaluation { evaluationToggle.switches.firstMatch.exists ? evaluationToggle.switches.firstMatch.tap() : evaluationToggle.tap() }
        continueButton.tap()
        let save = app.buttons["feedbackSave"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func tap(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) missing")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        _ = XCTWaiter().wait(for: [enabled], timeout: 15)
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
