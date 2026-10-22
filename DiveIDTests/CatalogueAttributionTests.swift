import XCTest
@testable import DiveID

final class CatalogueAttributionTests: XCTestCase {
    func testCreditsNameBothSourcesTheReleaseLicenceAndChanges() {
        XCTAssertEqual(CatalogueAttribution.credits.map(\.name), ["FishBase", "SeaLifeBase"])
        XCTAssertTrue(CatalogueAttribution.credits.allSatisfy { $0.release == "v26.06" && $0.citation.contains("Pauly") })
        XCTAssertEqual(CatalogueAttribution.licenseURL, "https://creativecommons.org/licenses/by-nc/4.0/")
        XCTAssertTrue(CatalogueAttribution.licenseNotice.contains("CC BY-NC 4.0"))
        XCTAssertTrue(CatalogueAttribution.modificationNotice.contains("changed"))
    }

    func testEveryApprovedGlobalRecordLinksToItsSourcePage() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication)
        let pack = try await repository.loadPack(id: .global)
        XCTAssertFalse(pack.profiles.isEmpty)
        for profile in pack.profiles {
            let lines = CatalogueAttribution.sourceLines(for: profile.dataSources)
            XCTAssertFalse(lines.isEmpty, profile.commonName)
            for line in lines {
                let url = try XCTUnwrap(line.url, profile.commonName)
                XCTAssertTrue(["www.fishbase.se", "www.sealifebase.se"].contains(url.host ?? ""), "\(profile.commonName): \(url)")
                XCTAssertTrue(line.text.contains("CC BY-NC 4.0"), profile.commonName)
            }
        }
    }
}
