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

    /// Every Global record, approved or not, links to its source page and licence.
    func testEveryGlobalRecordLinksToItsSourcePage() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let pack = try await repository.loadPack(id: .global)
        XCTAssertFalse(pack.profiles.isEmpty)
        // The 8 Caribbean species are the Caribbean pack's own records, carried into Global
        // with their own sources; they must credit exactly what the Caribbean pack credits.
        let caribbean = Dictionary(uniqueKeysWithValues: try await repository.loadPack(id: .caribbean).profiles.map { ($0.id, $0) })
        for profile in pack.profiles {
            let lines = CatalogueAttribution.sourceLines(for: profile.dataSources)
            XCTAssertFalse(lines.isEmpty, profile.commonName)
            if let regional = caribbean[profile.id] {
                let expected = CatalogueAttribution.sourceLines(for: regional.dataSources)
                XCTAssertEqual(lines.map(\.text), expected.map(\.text), profile.commonName)
                XCTAssertEqual(lines.map(\.url), expected.map(\.url), profile.commonName)
                XCTAssertTrue(lines.allSatisfy { $0.url != nil }, profile.commonName)
                continue
            }
            for line in lines {
                let url = try XCTUnwrap(line.url, profile.commonName)
                XCTAssertTrue(["www.fishbase.se", "www.sealifebase.se"].contains(url.host ?? ""), "\(profile.commonName): \(url)")
                XCTAssertTrue(line.text.contains("CC BY-NC 4.0"), profile.commonName)
            }
        }
    }
}
