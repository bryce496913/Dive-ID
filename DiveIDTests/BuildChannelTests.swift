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
        let listed = Set(try await repository.availablePacks().map(\.id))
        switch BuildChannel.current {
        case .release:
            // Only packs with approved records; Tropical Pacific has none.
            XCTAssertTrue(listed.contains(.caribbean))
            XCTAssertFalse(listed.contains(.tropicalPacific))
        case .debug, .internal:
            XCTAssertTrue(listed.isSuperset(of: [.caribbean, .tropicalPacific, .global]))
        }
    }
}
