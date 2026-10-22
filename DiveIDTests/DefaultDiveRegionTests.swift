import XCTest
@testable import DiveID

final class DefaultDiveRegionTests: XCTestCase {
    /// New installs start in a regional pack, never Global, until the Global gates pass.
    /// A stored selection, Global included, is kept.
    func testNewInstallsDefaultToARegionalPackAndStoredSelectionsAreKept() async {
        let suite = "DefaultDiveRegionTests.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let repository = UserDefaultsSelectedDiveRegionRepository(defaults: UserDefaults(suiteName: suite)!, key: "region")
        let fresh = await repository.selectedRegion()
        XCTAssertEqual(fresh, .caribbean)
        XCTAssertNotEqual(fresh, .global)
        XCTAssertEqual(DefaultDiveRegion.forNewInstalls, .caribbean)
        for stored in [OfflineIdentificationPackID.global, .tropicalPacific, .caribbean] {
            await repository.setSelectedRegion(stored)
            let selected = await repository.selectedRegion()
            XCTAssertEqual(selected, stored, "an existing user's selection is kept")
        }
    }
}
