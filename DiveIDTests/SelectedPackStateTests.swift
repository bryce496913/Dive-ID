import XCTest
@testable import DiveID

final class SelectedPackStateTests: XCTestCase {
    func testSelectedRegionWithReviewedPackLoadsThatPack() async {
        let caribbean = packMetadata(id: .caribbean, displayName: "Caribbean")
        let pacific = packMetadata(id: .tropicalPacific, displayName: "Tropical Pacific")
        let state = await loader(packs: [caribbean, pacific], selected: .tropicalPacific).load()

        XCTAssertEqual(state, .loaded(pacific))
        XCTAssertEqual(state.pack, pacific)
        XCTAssertTrue(state.canChangeRegion)
    }

    func testCatalogueErrorIsLoadFailed() async {
        let catalog = ResultsCatalogRepository(metadata: [packMetadata(id: .caribbean, displayName: "Caribbean")], error: LocalCatalogError.unreadableData)
        let state = await SelectedPackLoader(catalog: catalog, regionRepository: MutableSelectedDiveRegionRepository(initialRegion: .caribbean)).load()

        XCTAssertEqual(state, .loadFailed)
        XCTAssertNil(state.pack)
        XCTAssertFalse(state.canChangeRegion)
    }

    func testSelectedRegionWithoutReviewedPackIsUnavailableWhenAnotherRegionHasOne() async {
        let state = await loader(packs: [packMetadata(id: .caribbean, displayName: "Caribbean")], selected: .tropicalPacific).load()

        XCTAssertEqual(state, .selectedRegionUnavailable)
        XCTAssertTrue(state.isSelectedRegionUnavailable)
        XCTAssertNil(state.pack)
        XCTAssertTrue(state.canChangeRegion)
    }

    func testNoReviewedPackAnywhereIsNoReviewedCatalogue() async {
        let state = await loader(packs: [], selected: .caribbean).load()

        XCTAssertEqual(state, .noReviewedCatalogue)
        XCTAssertNil(state.pack)
        XCTAssertFalse(state.canChangeRegion)
    }

    func testNotLoadedHasNoPackAndCannotChangeRegion() {
        XCTAssertNil(SelectedPackState.notLoaded.pack)
        XCTAssertFalse(SelectedPackState.notLoaded.canChangeRegion)
    }

    func testEachLoadReadsTheCurrentSelection() async {
        let caribbean = packMetadata(id: .caribbean, displayName: "Caribbean")
        let regionRepository = MutableSelectedDiveRegionRepository(initialRegion: .tropicalPacific)
        let packLoader = SelectedPackLoader(catalog: ResultsCatalogRepository(metadata: [caribbean]), regionRepository: regionRepository, registry: Self.noRetirements)

        let before = await packLoader.load()
        XCTAssertEqual(before, .selectedRegionUnavailable)
        await regionRepository.setSelectedRegion(.caribbean)
        let after = await packLoader.load()
        XCTAssertEqual(after, .loaded(caribbean))
    }

    /// Loaders over an empty registry: these regions are plain IDs, none of them retired
    /// (retired regions: GlobalSubregionTests).
    private func loader(packs: [OfflineIdentificationPackMetadata], selected: OfflineIdentificationPackID) -> SelectedPackLoader {
        SelectedPackLoader(catalog: ResultsCatalogRepository(metadata: packs), regionRepository: MutableSelectedDiveRegionRepository(initialRegion: selected), registry: Self.noRetirements)
    }

    private static let noRetirements = RegionCatalogRegistry(definitions: [])

    private func packMetadata(id: OfflineIdentificationPackID, displayName: String) -> OfflineIdentificationPackMetadata {
        OfflineIdentificationPackMetadata(
            id: id, schemaVersion: 1, packVersion: 1, displayName: displayName,
            shortDescription: "Test metadata", geographicScope: "Test scope", regionAliases: [],
            speciesCount: 8, speciesResourceName: "TestSpecies", imageSubdirectory: "Images",
            includedWithApp: false, lastDataReviewDate: nil
        )
    }
}
