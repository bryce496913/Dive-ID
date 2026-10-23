import XCTest

final class DiveIDUITests: XCTestCase {
    @MainActor
    func testCoreOfflineNavigationSmokeFlow() {
        let spottedEagleRayResultIdentifier = "result_00000000-0000-0000-0000-000000000010"
        let app = XCUIApplication()
        // An existing user's stored Caribbean selection (a launch-argument default, not persisted).
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "caribbean"]
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

    /// A new install, with no stored selection, starts in the Global pack.
    @MainActor
    func testNewInstallStartsInGlobal() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Global"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFindMatchesStaysReachableWhileKeyboardIsShown() {
        assertFindMatchesReachableWithKeyboard(launchArguments: ["-uiTesting"])
    }

    @MainActor
    func testFindMatchesStaysReachableWhileKeyboardIsShownAtLargestDynamicType() {
        assertFindMatchesReachableWithKeyboard(launchArguments: ["-uiTesting", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    }

    @MainActor
    private func assertFindMatchesReachableWithKeyboard(launchArguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        let app = XCUIApplication()
        // An existing user's stored Caribbean selection, as in the smoke flow; new installs start in Global.
        app.launchArguments = launchArguments + ["-selectedDiveRegion", "caribbean"]
        app.launch()
        app.buttons["describeAction"].tap()
        XCTAssertTrue(app.staticTexts["Dive region: Caribbean"].waitForExistence(timeout: 2), file: file, line: line)
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2), file: file, line: line)
        editor.tap()
        editor.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        let findMatches = app.buttons["findMatches"]
        XCTAssertTrue(findMatches.isEnabled, file: file, line: line)
        XCTAssertTrue(findMatches.isHittable, file: file, line: line)
        // A simulator with a connected hardware keyboard shows no software keyboard; when it is shown,
        // the button must sit entirely above it.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(findMatches.frame.maxY, keyboard.frame.minY, file: file, line: line)
        }
        // A single tap dismisses the keyboard and submits.
        findMatches.tap()
        XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertFalse(app.keyboards.firstMatch.exists, file: file, line: line)
    }

    @MainActor
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
