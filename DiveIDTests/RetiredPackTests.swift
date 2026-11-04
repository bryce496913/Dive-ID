import XCTest
@testable import DiveID

/// The retired Caribbean and Tropical Pacific packs are test fixtures only: never in the app's
/// resources (the SwiftPM `DiveID` resources here, the app bundle in Xcode). What the app still
/// needs from them, the IDs, the "Dive region unavailable" recovery and saved identifications'
/// own snapshots, works without their records.
final class RetiredPackTests: XCTestCase {
    private let retired: [(id: OfflineIdentificationPackID, directory: String, name: String, replacement: OfflineIdentificationPackID)] = [
        (.caribbean, "Caribbean", "Caribbean", .tropicalAtlantic),
        (.tropicalPacific, "TropicalPacific", "Tropical Pacific", .indoPacific),
    ]

    func testNoRetiredPackFileIsInTheAppResources() throws {
        let packs = try XCTUnwrap(TestResources.productionBundle.resourceURL).appendingPathComponent("IdentificationPacks", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: packs.appendingPathComponent("Global/Creatures.json").path), "the app's packs are here")
        for pack in retired {
            for subdirectory in ["IdentificationPacks/\(pack.directory)", "IdentificationPacks/\(pack.directory)/Images"] {
                XCTAssertNil(TestResources.productionBundle.url(forResource: "Creatures", withExtension: "json", subdirectory: subdirectory))
                XCTAssertNil(TestResources.productionBundle.url(forResource: "PackManifest", withExtension: "json", subdirectory: subdirectory))
                XCTAssertEqual(TestResources.productionBundle.urls(forResourcesWithExtension: nil, subdirectory: subdirectory) ?? [], [],
                               "\(subdirectory) is in the app resources")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: packs.appendingPathComponent(pack.directory).path), "\(pack.directory) is bundled")
            XCTAssertNotNil(TestResources.fixturePackFile(pack.directory, "Creatures.json"), "\(pack.directory) is a test fixture")
        }
    }

    func testTheAppCannotOpenARetiredPackAndNeverListsOne() async throws {
        let app = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        for pack in retired {
            do {
                _ = try await app.loadPack(id: pack.id)
                XCTFail("\(pack.directory) opened from the app's resources")
            } catch let failure as CatalogueLoadFailure {
                XCTAssertEqual(failure.code, .manifestMissing)
            }
        }
        let listed = try await app.availablePacks().map(\.id)
        XCTAssertFalse(listed.contains(.caribbean) || listed.contains(.tropicalPacific))
        XCTAssertTrue(listed.contains(.global))
    }

    func testRecoveryStillOffersEachReplacementWithoutTheRecords() async {
        for pack in retired {
            let definition = RegionCatalogRegistry.bundled.definition(for: pack.id)
            XCTAssertEqual(definition?.retirement, RegionRetirement(displayName: pack.name, suggestedReplacement: pack.replacement))
            let loader = SelectedPackLoader(catalog: BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly,
                                                                                        access: .publication),
                                            regionRepository: MutableSelectedDiveRegionRepository(initialRegion: pack.id))
            guard case .selectedRegionRetired(let recovery) = await loader.load() else { return XCTFail("\(pack.name): no recovery screen") }
            XCTAssertEqual(recovery.retiredName, pack.name)
            XCTAssertEqual(recovery.suggestion?.id, pack.replacement)
        }
    }

    @MainActor
    func testASavedCaribbeanIdentificationOpensFromItsSnapshot() async throws {
        let caribbean = try await TestResources.catalogRepository(access: .experimentalDevelopment).loadPack(id: .caribbean)
        let profile = try XCTUnwrap(caribbean.profiles.first)
        var species = profile.species
        species.packContext = PackContext(packID: .caribbean, displayName: "Caribbean", packVersion: 1)
        let saved = SavedIdentification(match: IdentificationMatch(id: species.id, species: species, score: 0.7, scoreKind: .relativeMatch, explanation: "Matched clues"))
        let repository = InMemorySavedIdentificationRepository(initial: [saved])
        let page = SpeciesDetailViewModel(saved: saved, repository: repository)
        await page.load()
        XCTAssertTrue(page.isSaved)
        XCTAssertEqual(page.species.commonName, profile.commonName, "the snapshot, with no Caribbean pack in the app")
        XCTAssertEqual(page.species.packContext?.packID, .caribbean, "still says it came from the Caribbean pack")
    }
}
