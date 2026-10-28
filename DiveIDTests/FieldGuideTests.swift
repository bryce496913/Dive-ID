import XCTest
@testable import DiveID

/// The field guide: groups and regions derived from the catalogue, never excluding on
/// unknown distribution, family sections and filters, Release vs development exposure,
/// saving with no match, and the time to build its lists.
@MainActor
final class FieldGuideTests: XCTestCase {
    private func repository(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess = .publication) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access)
    }

    private func globalCatalogue() async throws -> (FieldGuideCatalogue, OfflineIdentificationPack) {
        let pack = try await repository().loadPack(id: .global)
        let context = PackContext(packID: .global, displayName: pack.metadata.displayName, packVersion: pack.metadata.packVersion)
        return (FieldGuideCatalogue(profiles: pack.profiles, packContext: context), pack)
    }

    func testGroupsComeFromTheCataloguesCategoriesWithInvertebratesBucketed() async throws {
        let (catalogue, pack) = try await globalCatalogue()
        let groups = catalogue.groups(in: .all)
        let expectedIDs = Set(pack.profiles.compactMap(\.categories.first).map(FieldGuideGroup.groupID(forCategory:)))
        XCTAssertEqual(Set(groups.map(\.id)), expectedIDs, "every group present in the data, and no other")
        XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, pack.profiles.count, "each species is in exactly one group")
        XCTAssertEqual(groups.first?.id, "fish", "largest first")
        let invertebrates = try XCTUnwrap(groups.first { $0.id == "invertebrates" })
        XCTAssertEqual(invertebrates.count, pack.profiles.filter { CatalogueVocabulary.invertebrateCategories.contains($0.categories.first ?? "") }.count)
        for name in ["Sharks", "Rays", "Eels", "Seahorses and pipefish", "Turtles", "Invertebrates", "Fish"] {
            XCTAssertTrue(groups.contains { $0.title == name }, name)
        }
        for group in groups {
            if let representative = group.representative { XCTAssertTrue(representative.hasPhoto, group.title) }
        }
        XCTAssertNotNil(groups.first { $0.id == "fish" }?.representative)
    }

    func testRegionsAreTheOceansTheDataSupportsAndUnknownDistributionIsNeverExcluded() async throws {
        let (catalogue, pack) = try await globalCatalogue()
        XCTAssertEqual(catalogue.regions.first, .all)
        XCTAssertEqual(Set(catalogue.regions.dropFirst().map(\.id)), ["pacific", "indian", "atlantic", "mediterranean", "arctic", "southern"])
        XCTAssertEqual(catalogue.count(in: .all), pack.profiles.count, "All regions lists every species")
        let unknown = catalogue.entries.filter(\.regions.isEmpty)
        XCTAssertEqual(unknown.count, catalogue.unknownDistributionCount)
        XCTAssertGreaterThan(unknown.count, 0)
        let caribbean = try XCTUnwrap(catalogue.entries.first { $0.species.commonName == "Queen Angelfish" })
        XCTAssertEqual(caribbean.regions.map(\.id), ["atlantic"], "no FAO area: falls back to the ocean its regions name")
        for region in catalogue.regions.dropFirst() {
            let listed = catalogue.entries(in: region)
            XCTAssertFalse(listed.isEmpty, region.title)
            XCTAssertTrue(listed.allSatisfy { !$0.regions.isEmpty }, "a specific region lists only recorded species")
        }
    }

    func testFAOAreaNamesMapToOceans() {
        XCTAssertEqual(FieldGuideRegion.regions(subregions: ["Western Central Pacific", "Eastern Indian Ocean"], regions: []).map(\.id).sorted(), ["indian", "pacific"])
        XCTAssertEqual(FieldGuideRegion.regions(subregions: ["Antarctic Atlantic"], regions: []).map(\.id), ["southern"])
        XCTAssertEqual(FieldGuideRegion.regions(subregions: ["Mediterranean and Black Sea"], regions: []).map(\.id), ["mediterranean"])
        XCTAssertEqual(FieldGuideRegion.regions(subregions: ["Bahamas"], regions: ["caribbean", "bahamas"]), [], "localities alone are unknown")
        XCTAssertEqual(FieldGuideRegion.regions(subregions: [], regions: ["indo-pacific"]).map(\.id), ["pacific"])
    }

    func testFamilySectionsNameFilterAndHasPhoto() async throws {
        let (catalogue, _) = try await globalCatalogue()
        let sections = catalogue.sections(group: "fish", region: .all)
        let families = sections.map(\.family)
        XCTAssertEqual(families.filter { $0 != FieldGuideCatalogue.unknownFamily },
                       families.filter { $0 != FieldGuideCatalogue.unknownFamily }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
        if families.contains(FieldGuideCatalogue.unknownFamily) { XCTAssertEqual(families.last, FieldGuideCatalogue.unknownFamily) }
        for section in sections.prefix(20) {
            let names = section.species.map(\.commonName)
            XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, section.family)
        }

        let common = catalogue.sections(group: "fish", region: .all, query: "queen ANGELFISH").flatMap(\.species).map(\.commonName)
        XCTAssertTrue(common.contains("Queen Angelfish"))
        let scientific = catalogue.sections(group: "fish", region: .all, query: "holacanthus ciliaris").flatMap(\.species).map(\.commonName)
        XCTAssertEqual(scientific, ["Queen Angelfish"])
        let aliased = try XCTUnwrap(catalogue.entries.first { $0.groupID == "fish" && !$0.species.aliases.isEmpty })
        let byAlias = catalogue.sections(group: "fish", region: .all, query: aliased.species.aliases[0]).flatMap(\.species)
        XCTAssertTrue(byAlias.contains { $0.id == aliased.species.id }, "aliases match too")
        XCTAssertTrue(catalogue.sections(group: "fish", region: .all, query: "zzzz-no-such").isEmpty)

        let photographed = catalogue.sections(group: "fish", region: .all, photosOnly: true).flatMap(\.species)
        XCTAssertFalse(photographed.isEmpty)
        XCTAssertTrue(photographed.allSatisfy(\.hasPhoto))
        XCTAssertTrue(catalogue.entries.allSatisfy { $0.species.packContext?.packID == .global }, "photos load from Global")
    }

    func testTheLastRegionIsRememberedAndTheUnknownNoteShowsOnlyForARegion() async throws {
        let store = MemoryRegionStore(saved: "indian")
        let guide = FieldGuideViewModel(catalog: repository(), regionStore: store)
        await guide.load()
        XCTAssertEqual(guide.region.id, "indian")
        XCTAssertNotNil(guide.unknownDistributionNote)
        guide.region = .all
        XCTAssertNil(guide.unknownDistributionNote)
        XCTAssertEqual(store.saved, "all")
        let stale = FieldGuideViewModel(catalog: repository(), regionStore: MemoryRegionStore(saved: "no-such-region"))
        await stale.load()
        XCTAssertEqual(stale.region, .all)
    }

    // MARK: Release shows approved records only; Internal (development access) shows drafts too

    func testReleaseShowsApprovedRecordsOnlyAndDevelopmentShowsDrafts() async throws {
        let root = try globalCopy(approved: 3)
        func guide(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) -> FieldGuideViewModel {
            FieldGuideViewModel(catalog: BundleMarineSpeciesCatalogRepository(
                bundle: Bundle(for: FieldGuideTests.self), registry: RegionCatalogRegistry(definitions: [GlobalRegion.definition]),
                resourceResolutionMode: .bundleThenDevelopmentSource, developmentSourceRoot: root, access: access),
                regionStore: MemoryRegionStore(saved: nil))
        }
        let release = guide(.publication)
        await release.load()
        XCTAssertEqual(release.catalogue?.entries.count, 3)
        XCTAssertTrue(release.catalogue?.entries.allSatisfy { $0.species.review?.status == .verified } ?? false)
        let development = guide(.experimentalDevelopment)
        await development.load()
        let all = try XCTUnwrap(development.catalogue?.entries.count)
        XCTAssertGreaterThan(all, 3, "Internal also lists the drafts")
        XCTAssertEqual(BuildChannel.release.catalogueAccess, .publication)
        XCTAssertEqual(BuildChannel.internal.catalogueAccess, .experimentalDevelopment)
    }

    // MARK: Saving with no match

    func testSavingFromTheFieldGuideKeepsNoMatchAndIsNotDuplicated() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let (catalogue, _) = try await globalCatalogue()
        let species = try XCTUnwrap(catalogue.entries.first?.species)
        let page = SpeciesDetailViewModel(species: species, match: nil, repository: repository)
        await page.load()
        XCTAssertFalse(page.isSaved)
        await page.toggleSaved()
        XCTAssertTrue(page.isSaved)
        let saved = try await repository.fetchAll()
        XCTAssertEqual(saved.count, 1)
        XCTAssertTrue(saved[0].isFromFieldGuide)
        XCTAssertNil(saved[0].sourceSessionID)
        XCTAssertNil(SpeciesDetailViewModel(saved: saved[0], repository: repository).match, "no strength or evidence is implied")

        let again = SpeciesDetailViewModel(species: species, match: nil, repository: repository)
        await again.load()
        XCTAssertTrue(again.isSaved, "recognised when the species page opens again")
        _ = try await repository.save(SavedIdentification(fieldGuideSpecies: species))
        let afterDuplicate = try await repository.fetchAll()
        XCTAssertEqual(afterDuplicate.count, 1)
        await again.toggleSaved()
        let afterRemove = try await repository.fetchAll()
        XCTAssertEqual(afterRemove.count, 0)
    }

    func testSavedFromRoundTripsAndOlderRecordsDecodeAsSearches() throws {
        let species = Species(id: UUID(), commonName: "Synthetic", scientificName: "Synthetica", summary: "", visualCharacteristics: [], habitat: "", geographicRange: "", imageAssetName: nil)
        let data = try JSONEncoder().encode(SavedIdentification(fieldGuideSpecies: species))
        XCTAssertTrue(try JSONDecoder().decode(SavedIdentification.self, from: data).isFromFieldGuide)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "savedFrom")
        let legacy = try JSONDecoder().decode(SavedIdentification.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.savedFrom)
        XCTAssertFalse(legacy.isFromFieldGuide)
    }

    // MARK: Performance (run with swift test -c release for the reported figure)

    func testBuildingTheGuideAndTheLargestGroupIsFast() async throws {
        let pack = try await repository().loadPack(id: .global)
        let context = PackContext(packID: .global, displayName: pack.metadata.displayName, packVersion: pack.metadata.packVersion)
        let clock = ContinuousClock()
        var catalogue: FieldGuideCatalogue!
        let build = clock.measure { catalogue = FieldGuideCatalogue(profiles: pack.profiles, packContext: context) }
        let groups = clock.measure { _ = catalogue.groups(in: .all) }
        var largest = 0
        let sections = clock.measure { largest = catalogue.sections(group: "fish", region: .all).reduce(0) { $0 + $1.species.count } }
        let filtered = clock.measure { _ = catalogue.sections(group: "fish", region: .all, query: "angel", photosOnly: true) }
        XCTAssertGreaterThan(largest, 3000, "the largest group has more than 3,000 rows")
        let ms = { (d: Duration) in Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000 }
        print(String(format: "FIELD_GUIDE_TIMING records=%d build=%.1fms groups=%.1fms fishSections(%d rows)=%.1fms filter=%.1fms",
                     pack.profiles.count, ms(build), ms(groups), largest, ms(sections), ms(filtered)))
        // Generous bounds for a debug build on a loaded CI host; the release figure is reported.
        XCTAssertLessThan(ms(build), 2000)
        XCTAssertLessThan(ms(sections), 1000)
    }

    // MARK: Helpers

    /// Global with only the first `approved` records verified and the rest drafts.
    private func globalCopy(approved: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = try XCTUnwrap(TestResources.productionBundle.resourceURL).appendingPathComponent("IdentificationPacks/Global", isDirectory: true)
        let destination = root.appendingPathComponent("IdentificationPacks/Global", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("Creatures.json"))) as? [[String: Any]])
        for index in records.indices where index >= approved {
            records[index]["review"] = ["status": "draft", "verifiedBy": NSNull(), "reviewDate": NSNull(), "reviewerNotes": NSNull()]
        }
        try JSONSerialization.data(withJSONObject: records).write(to: destination.appendingPathComponent("Creatures.json"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("PackManifest.json"))) as? [String: Any])
        manifest["humanReviewedRecordCount"] = approved
        manifest["publicationEligibleRecordCount"] = approved
        try JSONSerialization.data(withJSONObject: manifest).write(to: destination.appendingPathComponent("PackManifest.json"))
        let images = source.appendingPathComponent("Images", isDirectory: true)
        if FileManager.default.fileExists(atPath: images.path) {
            try FileManager.default.copyItem(at: images, to: destination.appendingPathComponent("Images", isDirectory: true))
        }
        return root
    }
}

private final class MemoryRegionStore: FieldGuideRegionStore, @unchecked Sendable {
    var saved: String?
    init(saved: String?) { self.saved = saved }
    func load() -> String? { saved }
    func save(_ id: String) { saved = id }
}
