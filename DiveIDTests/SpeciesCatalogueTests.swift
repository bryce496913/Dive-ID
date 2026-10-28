import XCTest
@testable import DiveID

/// Browse All Species: every species of the selected region, in name order, filterable by
/// name and by having a photo, each carrying the region so derived packs show Global's photos.
@MainActor
final class SpeciesCatalogueTests: XCTestCase {
    private func model(region: OfflineIdentificationPackID) -> SpeciesCatalogueViewModel {
        SpeciesCatalogueViewModel(
            catalog: BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication),
            regionRepository: MutableSelectedDiveRegionRepository(initialRegion: region))
    }

    func testListsEveryRegionSpeciesInNameOrderWithTheRegionAttached() async throws {
        let catalogue = model(region: .tropicalAtlantic)
        await catalogue.load()
        let pack = try XCTUnwrap(catalogue.pack)
        XCTAssertEqual(catalogue.species.count, pack.speciesCount)
        let names = catalogue.species.map(\.commonName)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        XCTAssertTrue(catalogue.species.allSatisfy { $0.packContext?.packID == .tropicalAtlantic })
        XCTAssertNil(catalogue.errorMessage)
    }

    func testFiltersByEveryTypedNameWordAndByPhoto() async throws {
        let catalogue = model(region: .global)
        await catalogue.load()
        catalogue.searchText = "queen ANGELFISH"
        XCTAssertEqual(catalogue.visibleSpecies.map(\.commonName), ["Queen Angelfish", "Queensland yellowtail angelfish"],
                       "every word must appear, as the start of a word or inside one, as when typing")
        catalogue.searchText = "Holacanthus ciliaris"
        XCTAssertEqual(catalogue.visibleSpecies.map(\.commonName), ["Queen Angelfish"], "scientific names match too")
        catalogue.searchText = ""
        catalogue.photosOnly = true
        XCTAssertEqual(catalogue.visibleSpecies.count, catalogue.photoCount)
        XCTAssertGreaterThan(catalogue.photoCount, 0)
        XCTAssertTrue(catalogue.visibleSpecies.allSatisfy(\.hasPhoto))
        catalogue.photosOnly = false
        XCTAssertEqual(catalogue.visibleSpecies.count, catalogue.species.count)
    }

    func testAFailedLoadShowsAnErrorAndNoSpecies() async throws {
        let real = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication)
        let packs = try await real.availablePacks()
        let global = try XCTUnwrap(packs.first { $0.id == .global })
        // Lists the pack, but loading it fails.
        let catalogue = SpeciesCatalogueViewModel(catalog: ResultsCatalogRepository(metadata: [global], error: nil),
                                                  regionRepository: MutableSelectedDiveRegionRepository(initialRegion: .global))
        await catalogue.load()
        XCTAssertEqual(catalogue.species, [])
        XCTAssertNotNil(catalogue.errorMessage)
    }
}
