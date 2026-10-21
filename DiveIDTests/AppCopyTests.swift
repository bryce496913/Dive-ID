import XCTest
@testable import DiveID

final class AppCopyTests: XCTestCase {
    func testDisclaimersKeepTheirSafetyMeaning() {
        XCTAssertTrue(AppCopy.accuracyDisclaimer.contains("not confirmed identifications"))
        XCTAssertTrue(AppCopy.matchStrengthDisclaimer.contains("not a probability"))
        XCTAssertTrue(AppCopy.draftCatalogueWarning.contains("have not been verified"))
        XCTAssertTrue(AppCopy.draftRecordStatus("Draft").contains("draft record; identity and biological details have not been verified"))
    }

    func testCatalogueLoadFailureMessageIsSharedWithResults() async {
        let message = await IdentificationResultsViewModel.message(for: .catalogUnavailable, includesDiagnostics: false)
        XCTAssertEqual(message, AppCopy.catalogueLoadFailed)
    }
}
