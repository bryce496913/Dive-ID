import Foundation
import XCTest
@testable import DiveID

/// The build channel decides catalogue access. Release must stay publication-only;
/// Debug and the optimized Internal configuration open the development catalogue.
final class BuildChannelTests: XCTestCase {
    func testOnlyReleaseIsLimitedToPublication() {
        XCTAssertEqual(BuildChannel.release.catalogueAccess, .publication)
        XCTAssertEqual(BuildChannel.debug.catalogueAccess, .experimentalDevelopment)
        XCTAssertEqual(BuildChannel.internal.catalogueAccess, .experimentalDevelopment)
    }

    func testOnlyReleaseHidesDiagnosticCodes() {
        XCTAssertFalse(BuildChannel.release.showsDiagnosticCodes)
        XCTAssertTrue(BuildChannel.debug.showsDiagnosticCodes)
        XCTAssertTrue(BuildChannel.internal.showsDiagnosticCodes)
    }

    func testCurrentChannelFollowsCompilationConditions() {
#if DEBUG
        XCTAssertEqual(BuildChannel.current, .debug)
#elseif DIVEID_INTERNAL
        XCTAssertEqual(BuildChannel.current, .internal)
#else
        XCTAssertEqual(BuildChannel.current, .release)
#endif
    }

    /// The repository's default access (no `access:` argument) is the one the app uses.
    func testDefaultRepositoryAccessMatchesTheChannel() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle)
        let listed = try await repository.availablePacks()
        XCTAssertEqual(listed.map(\.id), [.global, .tropicalAtlantic, .indoPacific, .pacificCoast, .mediterranean],
                       "every channel lists Global and its regions; retired regions never")
        switch BuildChannel.current {
        case .release:
            // Approved records only: Global's drafts stay out of every region.
            XCTAssertTrue(listed.allSatisfy { $0.speciesCount == $0.publicationEligibleRecordCount })
        case .debug, .internal:
            XCTAssertTrue(listed.allSatisfy { $0.speciesCount == $0.includedRecordCount })
            let fixture = try await repository.loadPack(id: .caribbean)
            XCTAssertFalse(fixture.profiles.isEmpty, "development builds still open a retired region by ID")
        }
    }
}
