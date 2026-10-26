import Foundation
import XCTest
@testable import DiveID

/// The dive regions drawn from Global (owner decision, 2026-10-26): Global plus four
/// regions whose records are Global's own, kept by Tools/FishBaseIntake/derive_regions.py.
/// Caribbean and Tropical Pacific are retired: never listed, never opened in Release.
final class GlobalSubregionTests: XCTestCase {
    private typealias Access = BundleMarineSpeciesCatalogRepository.CatalogueAccess
    private static let offered: [OfflineIdentificationPackID] = [.global, .tropicalAtlantic, .indoPacific, .pacificCoast, .mediterranean]
    private static let derived: [OfflineIdentificationPackID] = [.tropicalAtlantic, .indoPacific, .pacificCoast, .mediterranean]

    private func repository(_ access: Access) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource, access: access)
    }

    private func membership(_ id: OfflineIdentificationPackID) throws -> Set<UUID> {
        let directory = try XCTUnwrap(RegionCatalogRegistry.bundled.definition(for: id)).resourceDirectory
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DiveID/Resources/IdentificationPacks/\(directory)/Members.json")
        return Set(try JSONDecoder().decode(RegionMembership.self, from: Data(contentsOf: url)).speciesIDs)
    }

    func testEveryBuildListsGlobalAndTheFourRegionsWithDescriptions() async throws {
        for access in [Access.experimentalDevelopment, .publication] {
            let packs = try await repository(access).availablePacks()
            XCTAssertEqual(packs.map(\.id), Self.offered, "\(access): Caribbean and Tropical Pacific are retired")
            XCTAssertEqual(packs.map(\.displayName), ["Global", "Tropical Atlantic Regions", "Indo-Pacific Regions", "Pacific Coast Regions", "Mediterranean"])
            for pack in packs where pack.id != .global {
                XCTAssertFalse(pack.geographicScope.isEmpty, "\(pack.displayName) names the places it covers")
            }
        }
        let scopes = try await repository(.publication).availablePacks().reduce(into: [OfflineIdentificationPackID: String]()) { $0[$1.id] = $1.geographicScope }
        XCTAssertTrue(try XCTUnwrap(scopes[.tropicalAtlantic]).contains("Caribbean Sea"))
        XCTAssertTrue(try XCTUnwrap(scopes[.indoPacific]).contains("Red Sea"))
        XCTAssertTrue(try XCTUnwrap(scopes[.pacificCoast]).contains("Galápagos"))
        XCTAssertTrue(try XCTUnwrap(scopes[.mediterranean]).contains("Black Sea"))
    }

    func testEachRegionHoldsExactlyItsMembersAsGlobalHasThem() async throws {
        let development = repository(.experimentalDevelopment)
        let global = try await development.loadPack(id: .global)
        let globalByID = Dictionary(uniqueKeysWithValues: global.profiles.map { ($0.id, $0) })
        for id in Self.derived {
            let pack = try await development.loadPack(id: id)
            let members = try membership(id)
            XCTAssertEqual(Set(pack.profiles.map(\.id)), members, "\(id.rawValue)")
            XCTAssertEqual(pack.metadata.speciesCount, members.count)
            for profile in pack.profiles {
                XCTAssertEqual(profile, globalByID[profile.id], "\(profile.commonName) is Global's record, unchanged")
            }
        }
    }

    func testReleaseShowsOnlyApprovedGlobalRecordsInEachRegion() async throws {
        let release = repository(.publication)
        let globalPack = try await release.loadPack(id: .global)
        let approvedGlobal = Set(globalPack.profiles.map(\.id))
        let listed = try await release.availablePacks()
        for id in Self.derived {
            let pack = try await release.loadPack(id: id)
            let ids = Set(pack.profiles.map(\.id))
            XCTAssertTrue(pack.profiles.allSatisfy { $0.review?.status == .verified }, "\(id.rawValue) shows no draft")
            XCTAssertEqual(ids, try membership(id).intersection(approvedGlobal), "\(id.rawValue) is its members' approved Global records")
            XCTAssertEqual(pack.metadata.speciesCount, pack.metadata.publicationEligibleRecordCount)
            XCTAssertEqual(listed.first { $0.id == id }, pack.metadata, "the listing matches the opened pack")
            XCTAssertNotEqual(pack.persistentContentKey, nil)
            XCTAssertNotEqual(pack.persistentContentKey, globalPack.persistentContentKey,
                              "a region's stored search index is its own")
        }
    }

    /// A species belongs to every region it occurs in, and the regions follow where it lives.
    func testRegionsFollowWhereSpeciesOccur() async throws {
        let release = repository(.publication)
        var names: [OfflineIdentificationPackID: Set<String>] = [:]
        for id in Self.derived { names[id] = Set(try await release.loadPack(id: id).profiles.map(\.commonName)) }
        let atlantic = try XCTUnwrap(names[.tropicalAtlantic]), indoPacific = try XCTUnwrap(names[.indoPacific])
        let coast = try XCTUnwrap(names[.pacificCoast]), mediterranean = try XCTUnwrap(names[.mediterranean])
        XCTAssertTrue(atlantic.isSuperset(of: ["Queen Angelfish", "Atlantic Blue Tang", "Stoplight Parrotfish"]))
        XCTAssertTrue(indoPacific.isSuperset(of: ["Whitetip reef shark", "Reef manta ray", "Achilles tang"]))
        XCTAssertTrue(coast.contains("Garibaldi damselfish"))
        XCTAssertFalse(indoPacific.contains("Garibaldi damselfish"))
        XCTAssertFalse(coast.contains("Reef manta ray"), "Hawaii and Polynesia are Indo-Pacific, not the Americas' Pacific coast")
        XCTAssertFalse(atlantic.contains("Achilles tang"))
        XCTAssertFalse(mediterranean.isEmpty)
        XCTAssertTrue(atlantic.contains("Whale shark") && indoPacific.contains("Whale shark") && coast.contains("Whale shark"),
                      "a species occurring in several regions is in each")
    }

    func testRegionalSearchReturnsOnlyThatRegionsApprovedRecords() async throws {
        let release = repository(.publication)
        let service = LocalMarineLifeIdentificationService(catalogRepository: release, parser: LocalObservationParser(), ranker: LocalSpeciesRanker())
        for (id, description) in [(OfflineIdentificationPackID.tropicalAtlantic, "Blue reef fish with a yellow tail spine, oval body"),
                                  (.indoPacific, "Large black and white manta ray gliding over the reef"),
                                  (.pacificCoast, "Compressed damselfish with a forked tail and spots on a shallow reef"),
                                  (.mediterranean, "Small striped fish over seagrass")] {
            let pack = try await release.loadPack(id: id)
            let allowed = Set(pack.profiles.map(\.id))
            let matches = try await service.identify(request: IdentificationRequest(source: .description(description), context: .init(region: id)), processedPhoto: nil)
            XCTAssertFalse(matches.isEmpty, "\(id.rawValue)")
            XCTAssertLessThanOrEqual(matches.count, 10)
            for match in matches {
                XCTAssertTrue(allowed.contains(match.species.id), "\(match.species.commonName) is outside \(id.rawValue)")
                XCTAssertEqual(match.packContext?.packID, id)
            }
        }
    }

    func testRetiredRegionsNeverOpenInRelease() async throws {
        for id in [OfflineIdentificationPackID.caribbean, .tropicalPacific] {
            do {
                _ = try await repository(.publication).loadPack(id: id)
                XCTFail("Release must not open retired \(id.rawValue)")
            } catch let failure as CatalogueLoadFailure {
                XCTAssertEqual(failure.code, .publicationUnavailable)
            }
            let fixture = try await repository(.experimentalDevelopment).loadPack(id: id)
            XCTAssertFalse(fixture.profiles.isEmpty, "Debug and tests still open \(id.rawValue) as an evaluation fixture")
        }
    }

    // MARK: - Membership integrity

    /// A derived region over a copy of the Caribbean pack, whose membership a test may edit.
    private func derivedCopy(members: (Set<String>) -> [String]) throws -> BundleMarineSpeciesCatalogRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = try XCTUnwrap(TestResources.productionBundle.resourceURL).appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("IdentificationPacks"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("IdentificationPacks/Caribbean"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("Creatures.json"))) as? [[String: Any]])
        let ids = members(Set(records.compactMap { $0["id"] as? String }))
        let chosen = records.filter { ids.contains($0["id"] as? String ?? "") }
        let status = { (record: [String: Any]) in (record["review"] as? [String: Any])?["status"] as? String }
        let reviewed = chosen.filter { ["sourceChecked", "verified"].contains(status($0) ?? "") }.count
        let eligible = chosen.filter { status($0) == "verified" && !(($0["categories"] as? [String]) ?? []).isEmpty }.count
        let region = root.appendingPathComponent("IdentificationPacks/Subset", isDirectory: true)
        try FileManager.default.createDirectory(at: region, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["sourcePackID": "caribbean", "speciesIDs": ids]).write(to: region.appendingPathComponent("Members.json"))
        let manifest: [String: Any] = [
            "id": "subset", "schemaVersion": 1, "packVersion": 1, "displayName": "Subset", "shortDescription": "Test",
            "geographicScope": "Test scope", "regionAliases": [], "speciesCount": ids.count, "speciesResourceName": "Members",
            "imageSubdirectory": "Images", "includedWithApp": true, "lastDataReviewDate": NSNull(),
            "includedRecordCount": ids.count, "humanReviewedRecordCount": reviewed, "publicationEligibleRecordCount": eligible,
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: region.appendingPathComponent("PackManifest.json"))
        return BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: GlobalSubregionTests.self),
            registry: RegionCatalogRegistry(definitions: [
                RegionCatalogDefinition(id: .caribbean, resourceDirectory: "Caribbean"),
                RegionCatalogDefinition(id: OfflineIdentificationPackID(rawValue: "subset"), resourceDirectory: "Subset", derivedFrom: .caribbean),
            ]),
            resourceResolutionMode: .bundleThenDevelopmentSource, developmentSourceRoot: root, access: .experimentalDevelopment)
    }

    private func failureCode(_ repository: BundleMarineSpeciesCatalogRepository) async -> CatalogueDiagnosticCode? {
        do { _ = try await repository.loadPack(id: OfflineIdentificationPackID(rawValue: "subset")); return nil }
        catch let failure as CatalogueLoadFailure { return failure.code } catch { return nil }
    }

    func testAMembershipNamingAnUnknownOrRepeatedRecordFailsClosed() async throws {
        let valid = try derivedCopy { Array($0.sorted().prefix(3)) }
        let pack = try await valid.loadPack(id: OfflineIdentificationPackID(rawValue: "subset"))
        XCTAssertEqual(pack.profiles.count, 3)
        let unknown = try derivedCopy { Array($0.sorted().prefix(2)) + ["00000000-0000-0000-0000-00000000FFFF"] }
        let unknownCode = await failureCode(unknown)
        XCTAssertEqual(unknownCode, .countMismatch)
        let repeated = try derivedCopy { let first = $0.sorted()[0]; return [first, first] }
        let repeatedCode = await failureCode(repeated)
        XCTAssertEqual(repeatedCode, .countMismatch)
    }

    // MARK: - Stored selections of retired regions

    private func loader(selected: OfflineIdentificationPackID, available: [OfflineIdentificationPackMetadata]) -> (SelectedPackLoader, MutableSelectedDiveRegionRepository) {
        let regions = MutableSelectedDiveRegionRepository(initialRegion: selected)
        return (SelectedPackLoader(catalog: ResultsCatalogRepository(metadata: available), regionRepository: regions), regions)
    }

    func testARetiredSelectionIsOfferedItsReplacementWithoutSwitching() async throws {
        let available = try await repository(.publication).availablePacks()
        let atlantic = try XCTUnwrap(available.first { $0.id == .tropicalAtlantic })
        let indoPacific = try XCTUnwrap(available.first { $0.id == .indoPacific })
        for (retired, name, replacement) in [(OfflineIdentificationPackID.caribbean, "Caribbean", atlantic), (.tropicalPacific, "Tropical Pacific", indoPacific)] {
            let (packLoader, regions) = loader(selected: retired, available: available)
            let state = await packLoader.load()
            XCTAssertEqual(state, .selectedRegionRetired(RetiredRegionRecovery(retiredName: name, suggestion: replacement)))
            XCTAssertNil(state.pack)
            XCTAssertTrue(state.canChangeRegion)
            XCTAssertTrue(state.isSelectedRegionUnavailable)
            let stored = await regions.selectedRegion()
            XCTAssertEqual(stored, retired, "nothing is substituted until the person chooses")
            let chosen = await packLoader.choose(replacement.id)
            XCTAssertEqual(chosen, .loaded(replacement))
        }
    }

    func testARetiredSelectionWithoutItsReplacementStillRecovers() async throws {
        let available = try await repository(.publication).availablePacks()
        let global = try XCTUnwrap(available.first { $0.id == .global })
        let state = await loader(selected: .caribbean, available: [global]).0.load()
        guard case .selectedRegionRetired(let recovery) = state else { return XCTFail("\(state)") }
        XCTAssertNil(recovery.suggestion)
        XCTAssertEqual(recovery.message, "Caribbean is no longer offered as a dive region. Choose another dive region to continue.")
        let unknown = await loader(selected: OfflineIdentificationPackID(rawValue: "atlantis"), available: [global]).0.load()
        XCTAssertEqual(unknown, .selectedRegionUnavailable, "an unknown region keeps the generic recovery")
    }
}
