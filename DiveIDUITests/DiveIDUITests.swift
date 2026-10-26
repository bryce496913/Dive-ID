import XCTest

final class DiveIDUITests: XCTestCase {
    @MainActor
    func testCoreOfflineNavigationSmokeFlow() {
        let spottedEagleRayResultIdentifier = "result_00000000-0000-0000-0000-000000000010"
        let app = XCUIApplication()
        // A stored Tropical Atlantic selection (a launch-argument default, not persisted).
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic"]
        app.launch()
        XCTAssertTrue(app.buttons["describeAction"].waitForExistence(timeout: 10))
        // On a small screen the longer region name pushes the lazily built tiles below the fold.
        let photo = app.buttons["photoAction"]
        for _ in 0..<4 where !photo.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(photo.exists)
        XCTAssertFalse(app.staticTexts["configuration error"].exists)
        for _ in 0..<4 where !app.buttons["describeAction"].isHittable { app.swipeDown(velocity: .slow) }
        tapSettled(app, app.buttons["describeAction"])
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 5))
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        tapSettled(app, editor)
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
        tapSettled(app, app.buttons["describeAction"])
        XCTAssertTrue(app.staticTexts["Dive region: Global"].waitForExistence(timeout: 5))
    }

    /// The region list offers Global and the four regions drawn from it, each describing the
    /// places it covers; the retired Caribbean and Tropical Pacific regions are not offered.
    @MainActor
    func testRegionListOffersGlobalAndItsRegions() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        tapSettled(app, app.buttons["offlinePackSummary"])
        XCTAssertTrue(app.navigationBars["Dive Region"].waitForExistence(timeout: 5))
        for id in ["global", "tropical-atlantic", "indo-pacific", "pacific-coast", "mediterranean"] {
            let row = app.buttons["region_\(id)"]
            for _ in 0..<4 where !row.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists, "region \(id) is not offered")
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Mediterranean Sea and Black Sea'")).firstMatch.exists)
        for _ in 0..<4 { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Caribbean Sea'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["region_caribbean"].exists)
        XCTAssertFalse(app.buttons["region_tropical-pacific"].exists)
        // Choosing a region is kept; choose Global again so later tests see the new-install region.
        tapSettled(app, app.buttons["region_indo-pacific"])
        // Choosing a region returns to Home.
        tapSettled(app, app.buttons["describeAction"])
        XCTAssertTrue(app.staticTexts["Dive region: Indo-Pacific Regions"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tapSettled(app, app.buttons["offlinePackSummary"])
        tapSettled(app, app.buttons["region_global"])
    }

    /// A stored region that was retired (Caribbean) is reported unavailable with its suggested
    /// replacement; nothing changes until the replacement is chosen, and the choice is kept.
    @MainActor
    func testRetiredRegionOffersItsReplacementWithoutSwitching() {
        let app = XCUIApplication()
        // The launch-argument default stands in for an existing install's stored "caribbean".
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "caribbean"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Dive region unavailable"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Caribbean is no longer offered'")).firstMatch.exists)
        XCTAssertFalse(app.buttons["describeAction"].isEnabled, "no region was substituted")
        let suggestion = app.buttons["useSuggestedRegionAction"]
        XCTAssertTrue(suggestion.exists)
        XCTAssertTrue(suggestion.label.contains("Tropical Atlantic Regions"), suggestion.label)
        XCTAssertTrue(app.buttons["changeRegionAction"].exists)
        suggestion.tap()
        // The choice is stored; relaunch without the launch-argument default to read it back.
        app.terminate()
        app.launchArguments = ["-uiTesting"]
        app.launch()
        tapSettled(app, app.buttons["describeAction"])
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tapSettled(app, app.buttons["offlinePackSummary"])
        tapSettled(app, app.buttons["region_global"])
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
        // A stored Tropical Atlantic selection, as in the smoke flow; new installs start in Global.
        app.launchArguments = launchArguments + ["-selectedDiveRegion", "tropical-atlantic"]
        app.launch()
        tapSettled(app, app.buttons["describeAction"])
        XCTAssertTrue(app.staticTexts["Dive region: Tropical Atlantic Regions"].waitForExistence(timeout: 5), file: file, line: line)
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2), file: file, line: line)
        tapSettled(app, editor)
        editor.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        let findMatches = app.buttons["findMatches"]
        record(app, "keyboard-after-typing", elements: ["findMatches": findMatches, "editor": editor, "keyboard": app.keyboards.firstMatch])
        XCTAssertTrue(findMatches.isEnabled, file: file, line: line)
        XCTAssertTrue(findMatches.isHittable, file: file, line: line)
        // A simulator with a connected hardware keyboard shows no software keyboard; when it is shown,
        // the button must sit entirely above it.
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(findMatches.frame.maxY, keyboard.frame.minY, file: file, line: line)
            // Dismissed and shown again, with the description grown well past the editor's height,
            // the button is still entirely above the keyboard each time.
            for round in 1...2 {
                app.buttons["dismissKeyboard"].tap()
                XCTAssertTrue(keyboard.waitForNonExistence(timeout: 3), file: file, line: line)
                XCTAssertTrue(findMatches.isHittable, file: file, line: line)
                tapSettled(app, editor)
                XCTAssertTrue(keyboard.waitForExistence(timeout: 3), file: file, line: line)
                editor.typeText(" Seen gliding slowly along the reef edge at about ten metres, with a pointed snout, a dark back covered in pale rings and spots, and a white belly.")
                record(app, "keyboard-round-\(round)", elements: ["findMatches": findMatches, "editor": editor, "keyboard": keyboard])
                XCTAssertTrue(findMatches.isHittable, file: file, line: line)
                XCTAssertLessThanOrEqual(findMatches.frame.maxY, keyboard.frame.minY, file: file, line: line)
            }
        }
        // A single tap dismisses the keyboard and submits.
        findMatches.tap()
        XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertFalse(app.keyboards.firstMatch.exists, file: file, line: line)
    }

    /// At the largest accessibility text size, every Home action, the top result and the save
    /// button stay within the screen's width and can be scrolled to and tapped.
    @MainActor
    func testLayoutsFitAtLargestDynamicType() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-selectedDiveRegion", "tropical-atlantic", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        for identifier in ["offlinePackSummary", "describeAction", "photoAction", "savedAction", "creditsAction"] {
            assertFitsAndReachable(app.buttons[identifier], in: app, named: identifier)
        }
        // Scroll back to the top before opening Describe.
        for _ in 0..<8 where !app.buttons["describeAction"].isHittable { app.swipeDown() }
        tapSettled(app, app.buttons["describeAction"])
        let editor = app.textViews["descriptionText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2))
        editor.tap()
        editor.typeText("Large flat eagle ray with white spots and a long tail over sand in the Caribbean.")
        app.buttons["findMatches"].tap()
        XCTAssertTrue(app.navigationBars["Possible Matches"].waitForExistence(timeout: 3))
        let firstResult = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'result_'")).firstMatch
        let firstResultFound = firstResult.waitForExistence(timeout: 5)
        record(app, "results", elements: ["firstResult": firstResult], hierarchy: !firstResultFound)
        XCTAssertTrue(firstResultFound)
        XCTAssertEqual(firstResult.identifier, "result_00000000-0000-0000-0000-000000000010")
        assertFitsAndReachable(firstResult, in: app, named: "first result")
        record(app, "results-before-tap", elements: ["firstResult": firstResult])
        firstResult.tap()
        XCTAssertTrue(app.navigationBars["Spotted Eagle Ray"].waitForExistence(timeout: 2))
        let toggleSaved = app.buttons["toggleSaved"]
        record(app, "detail-opened", elements: ["toggleSaved": toggleSaved], hierarchy: true)
        assertFitsAndReachable(toggleSaved, in: app, named: "toggleSaved")
        record(app, "detail-after-scrolling", elements: ["toggleSaved": toggleSaved], hierarchy: !toggleSaved.isHittable)
    }

    /// At the largest text sizes the Describe card and the editor can be taller than the screen. XCUITest would
    /// scroll it into view and tap during the scroll's momentum, which iOS treats as stopping
    /// the scroll, not as a tap. Bring it into view first and let the scroll settle.
    @MainActor
    private func tapSettled(_ app: XCUIApplication, _ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        // Home enables Describe only once the catalogue has loaded; a tap before that does nothing.
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 15), .completed, "\(element) never became enabled")
        var scrolled = false
        for _ in 0..<6 where !element.isHittable { app.swipeUp(velocity: .slow); scrolled = true }
        if scrolled { Thread.sleep(forTimeInterval: 1) }
        // A tap during a push transition or the keyboard's dismissal is dropped: wait until the
        // element has stopped moving.
        var frame = element.frame
        for _ in 0..<12 {
            Thread.sleep(forTimeInterval: 0.25)
            let next = element.frame
            if next == frame { break }
            frame = next
        }
        element.tap()
    }

    /// Evidence for the result bundle: a screenshot, and optionally the accessibility hierarchy,
    /// kept whether or not the test passes; a one-line summary of each element's state also goes
    /// to the log (prefixed UIDIAG) so it is readable without the bundle.
    @MainActor
    private func record(_ app: XCUIApplication, _ name: String, elements: [String: XCUIElement], hierarchy: Bool = false) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name).png"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let window = app.windows.firstMatch.frame
        var line = "UIDIAG \(name) window=\(window)"
        for (label, element) in elements.sorted(by: { $0.key < $1.key }) {
            let exists = element.exists
            line += " | \(label) exists=\(exists)"
            if exists {
                line += " id=\(element.identifier) enabled=\(element.isEnabled) hittable=\(element.isHittable) frame=\(element.frame)"
            }
        }
        print(line)
        if hierarchy {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name)-hierarchy.txt"
            tree.lifetime = .keepAlways
            add(tree)
            print("UIDIAG-TREE \(name) BEGIN\n\(app.debugDescription)\nUIDIAG-TREE \(name) END")
        }
    }

    /// Scrolls until the element is hittable, then checks it does not run past either screen edge.
    @MainActor
    private func assertFitsAndReachable(_ element: XCUIElement, in app: XCUIApplication, named name: String, file: StaticString = #filePath, line: UInt = #line) {
        for swipe in 0..<8 where !(element.exists && element.isHittable) {
            print("UIDIAG reach \(name) swipe=\(swipe) exists=\(element.exists) frame=\(element.exists ? element.frame : .null)")
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, "\(name) could not be scrolled into view", file: file, line: line)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 1, "\(name) runs past the leading edge", file: file, line: line)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1, "\(name) runs past the trailing edge", file: file, line: line)
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
