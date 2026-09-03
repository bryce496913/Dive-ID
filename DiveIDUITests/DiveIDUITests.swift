import XCTest

final class DiveIDUITests: XCTestCase {
    func testCoreOfflineNavigationSmokeFlow() {
        let spottedEagleRayResultIdentifier = "result_00000000-0000-0000-0000-000000000010"
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.buttons["describeAction"].exists)
        XCTAssertTrue(app.buttons["photoAction"].exists)
        XCTAssertFalse(app.staticTexts["configuration error"].exists)
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Caribbean"].waitForExistence(timeout: 2))
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.tap()
        editor.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        XCTAssertTrue(app.buttons["findMatches"].isEnabled)
        app.buttons["findMatches"].tap()
        XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 3))
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 5))
        XCTAssertEqual(firstResult.identifier, spottedEagleRayResultIdentifier)
        let spottedEagleRayResult = app.buttons[spottedEagleRayResultIdentifier]
        XCTAssertTrue(spottedEagleRayResult.exists)
        XCTAssertFalse(app.otherElements["resultsLoading"].exists)
        spottedEagleRayResult.tap()
        XCTAssertTrue(app.navigationBars["Spotted Eagle Ray"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["toggleSaved"].waitForExistence(timeout: 2))
    }

    func testPhotoCardIsDisabledAndSavedScreenOpens() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["photoAction"].exists)
        XCTAssertTrue(app.staticTexts["Coming later"].exists)
        XCTAssertFalse(app.buttons["photoAction"].isEnabled)
        app.buttons["savedAction"].tap()
        XCTAssertTrue(app.navigationBars["Saved Identifications"].waitForExistence(timeout: 2))
    }
}
