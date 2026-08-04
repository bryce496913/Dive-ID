import XCTest

final class DiveIDUITests: XCTestCase {
    func testCoreNavigationSmokeFlow() {
        let app = XCUIApplication(); app.launchArguments = ["-uiTesting", "-mockIdentificationMode", "success"]; app.launch()
        XCTAssertTrue(app.buttons["describeAction"].exists); XCTAssertTrue(app.buttons["photoAction"].exists)
        app.buttons["describeAction"].tap(); let editor = app.textViews["descriptionText"]; XCTAssertTrue(editor.waitForExistence(timeout: 2)); editor.tap(); editor.typeText("Small yellow reef fish"); XCTAssertTrue(app.buttons["findMatches"].isEnabled); app.buttons["findMatches"].tap(); XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 3)); let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).firstMatch; XCTAssertTrue(result.waitForExistence(timeout: 3)); XCTAssertFalse(app.otherElements["resultsLoading"].exists); result.tap(); XCTAssertTrue(app.buttons["toggleSaved"].waitForExistence(timeout: 2)); app.navigationBars.buttons.firstMatch.tap(); XCTAssertTrue(result.exists)
    }
    func testPhotoAndSavedScreensOpen() { let app = XCUIApplication(); app.launch(); app.buttons["photoAction"].tap(); XCTAssertTrue(app.navigationBars["Identify From Photo"].exists); app.navigationBars.buttons.firstMatch.tap(); app.buttons["savedAction"].tap(); XCTAssertTrue(app.navigationBars["Saved Species"].exists) }
}
