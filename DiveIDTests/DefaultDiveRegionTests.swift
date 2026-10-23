import XCTest
@testable import DiveID

final class DefaultDiveRegionTests: XCTestCase {
    /// New installs start in Global. A stored selection, regional included, is kept.
    func testNewInstallsDefaultToGlobalAndStoredSelectionsAreKept() async {
        let suite = "DefaultDiveRegionTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let repository = UserDefaultsSelectedDiveRegionRepository(defaults: UserDefaults(suiteName: suite)!, key: "region")
        let fresh = await repository.selectedRegion()
        XCTAssertEqual(fresh, .global)
        XCTAssertEqual(DefaultDiveRegion.forNewInstalls, .global)
        for stored in [OfflineIdentificationPackID.caribbean, .tropicalPacific, .global] {
            await repository.setSelectedRegion(stored)
            let selected = await repository.selectedRegion()
            XCTAssertEqual(selected, stored, "an existing user's selection is kept")
        }
    }
}
