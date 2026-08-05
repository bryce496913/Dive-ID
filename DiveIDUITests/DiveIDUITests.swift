import XCTest

final class DiveIDUITests: XCTestCase {
    func testCoreOfflineNavigationSmokeFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        XCTAssertTrue(app.buttons["describeAction"].exists)
        XCTAssertTrue(app.buttons["photoAction"].exists)
        XCTAssertFalse(app.staticTexts["configuration error"].exists)
        app.buttons["describeAction"].tap()
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.tap()
        editor.typeText("Small blue fish with a yellow tail, about 20 cm, seen on a shallow reef in Fiji.")
        XCTAssertTrue(app.buttons["findMatches"].isEnabled)
        app.buttons["findMatches"].tap()
        XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 3))
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["resultsLoading"].exists)
        result.tap()
        XCTAssertTrue(app.buttons["toggleSaved"].waitForExistence(timeout: 2))
        app.buttons["toggleSaved"].tap()
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
