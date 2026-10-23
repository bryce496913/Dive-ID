import Foundation
import XCTest
@testable import DiveID

/// The Global pack ranks by location without excluding anyone (Docs/HybridRankingContract.md, "Location").
final class GlobalPackTests: XCTestCase {
    private func repository(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource, access: access)
    }

    private func copy(_ profile: LocalSpeciesProfile, id: String, name: String, regions: [String]) throws -> LocalSpeciesProfile {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object["id"] = id
        object["commonName"] = name
        object["regions"] = regions
        return try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// The bundled (empty) Global manifest holding three otherwise identical synthetic species.
    private func globalPack() async throws -> OfflineIdentificationPack {
        let manifest = try await repository(.experimentalDevelopment).loadPack(id: .global).metadata
        let base = try await repository(.experimentalDevelopment).loadPack(id: .caribbean).profiles[0]
        var metadata = manifest
        metadata.speciesCount = 3
        return OfflineIdentificationPack(metadata: metadata, profiles: [
            try copy(base, id: "00000000-0000-0000-0000-000000000301", name: "In Range", regions: ["caribbean", "western atlantic", "atlantic"]),
            try copy(base, id: "00000000-0000-0000-0000-000000000302", name: "Out Of Range", regions: ["indo-pacific", "pacific"]),
            try copy(base, id: "00000000-0000-0000-0000-000000000303", name: "Unknown Range", regions: [])
        ])
    }

    /// The approvals the published pack applied (written by publish_global.py from the
    /// recorded batch overlays): an approval whose record content changed since is stale
    /// and absent here. Python computes the fingerprints; test_publish_global keeps this file current.
    private func appliedApprovals() throws -> [UUID: RecordReviewMethod] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Data/CatalogReview/GlobalBatches/AppliedApprovals.json")
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var approved: [UUID: RecordReviewMethod] = [:]
        for (id, method) in try XCTUnwrap(document["approved"] as? [String: String]) {
            approved[try XCTUnwrap(UUID(uuidString: id))] = try XCTUnwrap(RecordReviewMethod(rawValue: method))
        }
        return approved
    }

    func testDevelopmentShowsTheWholeGlobalPackWithApprovedRecordsMarked() async throws {
        let development = try await repository(.experimentalDevelopment).availablePacks()
        let global = try XCTUnwrap(development.first { $0.id == .global })
        let approved = try appliedApprovals()
        XCTAssertGreaterThan(global.speciesCount, 4_000)
        XCTAssertEqual(global.includedRecordCount, global.speciesCount)
        XCTAssertEqual(global.publicationEligibleRecordCount, approved.count)
        XCTAssertTrue(global.isExperimental)
        XCTAssertEqual(global.displayName, "Global (Experimental)", "experimental until every record is approved")
        XCTAssertTrue(global.regionAliases.isEmpty, "the global pack never conflicts with a described location")
        XCTAssertEqual(Set(development.map(\.id)), [.caribbean, .tropicalPacific, .global], "existing packs stay in place")
        let pack = try await repository(.experimentalDevelopment).loadPack(id: .global)
        for profile in pack.profiles {
            if let method = approved[profile.id] {
                XCTAssertEqual(profile.review?.status, .verified)
                XCTAssertEqual(profile.review?.reviewMethod, method)
                XCTAssertEqual(profile.review?.verifiedBy, "Bryce")
            } else {
                XCTAssertEqual(profile.review?.status, .draft, "\(profile.commonName) has no approval")
                XCTAssertNil(profile.review?.reviewMethod)
            }
        }
    }

    /// The Global definition with the Release gate lifted, as an approved enabling change would set it.
    private static let ungatedGlobal = RegionCatalogDefinition(id: .global, resourceDirectory: "Global", availableInRelease: true)

    /// A copy of the bundled Global pack in which the first `approved` records are verified
    /// by a batch review and the manifest counts them, as publish_global.py would write it.
    private func globalCopyWithApprovedRecords(_ approved: Int) throws -> (root: URL, ids: Set<UUID>) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = try XCTUnwrap(TestResources.productionBundle.resourceURL).appendingPathComponent("IdentificationPacks/Global", isDirectory: true)
        let destination = root.appendingPathComponent("IdentificationPacks/Global", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("Creatures.json"))) as? [[String: Any]])
        var ids = Set<UUID>()
        for index in 0..<approved {
            records[index]["review"] = ["status": "verified", "verifiedBy": "Bryce", "reviewDate": "2026-10-23T00:00:00Z",
                                        "reviewerNotes": "Synthetic approval for the Release gate test.", "reviewMethod": "individually-reviewed"]
            ids.insert(try XCTUnwrap(UUID(uuidString: try XCTUnwrap(records[index]["id"] as? String))))
        }
        try JSONSerialization.data(withJSONObject: records).write(to: destination.appendingPathComponent("Creatures.json"))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("PackManifest.json"))) as? [String: Any])
        manifest["humanReviewedRecordCount"] = approved
        manifest["publicationEligibleRecordCount"] = approved
        try JSONSerialization.data(withJSONObject: manifest).write(to: destination.appendingPathComponent("PackManifest.json"))
        return (root, ids)
    }

    private func repository(root: URL, global: RegionCatalogDefinition, access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: GlobalPackTests.self), registry: RegionCatalogRegistry(definitions: [global]),
                                             resourceResolutionMode: .bundleThenDevelopmentSource, developmentSourceRoot: root, access: access)
    }

    private func assertPublicationUnavailable(_ repository: BundleMarineSpeciesCatalogRepository, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await repository.loadPack(id: .global)
            XCTFail("Release must not open the Global pack", file: file, line: line)
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .publicationUnavailable, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    /// Global is gated out of Release at pack level. Lifting the gate is a separate,
    /// explicitly approved change to GlobalRegion.definition; this test must change with it.
    func testGlobalIsGatedOutOfRelease() async throws {
        XCTAssertFalse(GlobalRegion.definition.availableInRelease)
        XCTAssertEqual(RegionCatalogRegistry.bundled.definition(for: .global)?.availableInRelease, false)
        XCTAssertEqual(RegionCatalogRegistry.bundled.definitions.filter { !$0.availableInRelease }.map(\.id), [.global], "only Global is gated")
        let release = repository(.publication)
        let available = try await release.availablePacks()
        XCTAssertFalse(available.contains { $0.id == .global })
        XCTAssertTrue(available.contains { $0.id == .caribbean }, "approved Caribbean records stay available")
        await assertPublicationUnavailable(release)
    }

    /// Approved records alone never publish Global: with two verified records the gated pack
    /// is still absent from Release, while the same files with the gate lifted would show
    /// exactly those two. Debug and Internal still open the whole pack.
    func testGlobalStaysOutOfReleaseEvenWhenSomeRecordsAreApproved() async throws {
        let (root, approved) = try globalCopyWithApprovedRecords(2)
        let gated = repository(root: root, global: GlobalRegion.definition, access: .publication)
        let listed = try await gated.availablePacks()
        XCTAssertTrue(listed.isEmpty, "a gated pack is not listed in Release")
        await assertPublicationUnavailable(gated)

        let development = try await repository(root: root, global: GlobalRegion.definition, access: .experimentalDevelopment).loadPack(id: .global)
        XCTAssertGreaterThan(development.profiles.count, 4_000)
        XCTAssertEqual(Set(development.profiles.filter { $0.review?.status == .verified }.map(\.id)), approved)

        // Control: the gate, not the review status, is what keeps these records out.
        let ungated = repository(root: root, global: Self.ungatedGlobal, access: .publication)
        let exposed = try await ungated.availablePacks()
        XCTAssertEqual(exposed.map(\.id), [.global])
        XCTAssertEqual(exposed.first?.speciesCount, 2)
        let ungatedPack = try await ungated.loadPack(id: .global)
        XCTAssertEqual(Set(ungatedPack.profiles.map(\.id)), approved)
    }

    /// With the gate lifted, publication access would expose exactly the records a
    /// recorded approval covers, and no draft.
    func testWithTheGateLiftedReleaseWouldExposeExactlyTheApprovedGlobalRecords() async throws {
        let approved = try appliedApprovals()
        let release = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle,
            registry: RegionCatalogRegistry(definitions: [CaribbeanRegion.definition, TropicalPacificRegion.definition, Self.ungatedGlobal]),
            resourceResolutionMode: .bundleThenDevelopmentSource, access: .publication)
        let available = try await release.availablePacks()
        XCTAssertTrue(available.contains { $0.id == .caribbean }, "approved Caribbean records stay available")
        guard !approved.isEmpty else {
            XCTAssertFalse(available.contains { $0.id == .global }, "no approval, no Global pack")
            return
        }
        let listed = try XCTUnwrap(available.first { $0.id == .global })
        XCTAssertEqual(listed.speciesCount, approved.count)
        XCTAssertEqual(listed.displayName, "Global (Experimental)")
        let pack = try await release.loadPack(id: .global)
        XCTAssertEqual(Set(pack.profiles.map(\.id)), Set(approved.keys))
        XCTAssertTrue(pack.profiles.allSatisfy { $0.review?.status == .verified })
        let full = try await repository(.experimentalDevelopment).loadPack(id: .global)
        let unapproved = Set(full.profiles.map(\.id)).subtracting(approved.keys)
        XCTAssertEqual(unapproved.count, full.profiles.count - approved.count)
        XCTAssertTrue(unapproved.isDisjoint(with: pack.profiles.map(\.id)), "unapproved records are absent")
    }

    func testDescribedLocationBoostsInRangeKeepsOutOfRangeAndUnknownIsNeutral() async throws {
        let pack = try await globalPack()
        let result = try await HybridDescriptionSearchEngine().search(description: "blue fish on a coral reef in the Bahamas", pack: pack)
        XCTAssertEqual(result.queryAnalysis.packRegionCompatibility, .unspecified, "a described location never mismatches the global pack")
        let byName = Dictionary(uniqueKeysWithValues: result.candidates.map { ($0.profile.commonName, $0) })
        let inRange = try XCTUnwrap(byName["In Range"])
        let outOfRange = try XCTUnwrap(byName["Out Of Range"], "out-of-range species are still returned")
        let unknown = try XCTUnwrap(byName["Unknown Range"], "species with no known range are still returned")
        XCTAssertEqual(result.candidates.first?.profile.commonName, "In Range", "in-range species rank first")
        XCTAssertTrue(inRange.matchedEvidence.contains("geographic range"))
        XCTAssertGreaterThan(inRange.rawScore, outOfRange.rawScore)
        XCTAssertEqual(outOfRange.rawScore, unknown.rawScore, "out of range is not evidence against the species")
        XCTAssertEqual(outOfRange.score, unknown.score, "confidence is unchanged")
        XCTAssertLessThan(outOfRange.orderingScore, unknown.orderingScore, "out of range is ordered below unknown range")
        XCTAssertEqual(result.candidates.map(\.profile.commonName), ["In Range", "Unknown Range", "Out Of Range"])
        XCTAssertFalse(outOfRange.conflictingEvidence.contains("geographic range"))
        XCTAssertFalse(unknown.matchedEvidence.contains("geographic range"))
    }

    func testDescriptionWithoutLocationTreatsEveryRangeAlike() async throws {
        let pack = try await globalPack()
        let result = try await HybridDescriptionSearchEngine().search(description: "blue fish on a coral reef", pack: pack)
        XCTAssertEqual(result.candidates.count, 3)
        XCTAssertEqual(Set(result.candidates.map(\.rawScore)).count, 1, "with no location, range neither helps nor hurts")
    }
}
