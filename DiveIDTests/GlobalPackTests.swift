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

    /// The record IDs and methods approved in the recorded batch overlays
    /// (Data/CatalogReview/GlobalBatches), the only source of Global approvals.
    private func approvedInOverlays() throws -> [UUID: RecordReviewMethod] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Data/CatalogReview/GlobalBatches")
        var approved: [UUID: RecordReviewMethod] = [:]
        let batches = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for batch in batches {
            for file in try FileManager.default.contentsOfDirectory(at: batch, includingPropertiesForKeys: nil) where file.lastPathComponent.contains("Review") {
                let overlay = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                guard overlay["decision"] as? String == "approved" else { continue }
                for record in try XCTUnwrap(overlay["records"] as? [[String: Any]]) {
                    let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(record["speciesID"] as? String)))
                    approved[id] = try XCTUnwrap(RecordReviewMethod(rawValue: try XCTUnwrap(record["reviewMethod"] as? String)))
                }
            }
        }
        return approved
    }

    func testDevelopmentShowsTheWholeGlobalPackWithApprovedRecordsMarked() async throws {
        let development = try await repository(.experimentalDevelopment).availablePacks()
        let global = try XCTUnwrap(development.first { $0.id == .global })
        let approved = try approvedInOverlays()
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

    /// Release (publication access) exposes exactly the records a recorded approval
    /// covers, and no draft.
    func testReleaseExposesExactlyTheApprovedGlobalRecords() async throws {
        let approved = try approvedInOverlays()
        let release = repository(.publication)
        let available = try await release.availablePacks()
        XCTAssertTrue(available.contains { $0.id == .caribbean }, "approved Caribbean records stay available")
        guard !approved.isEmpty else {
            XCTAssertFalse(available.contains { $0.id == .global }, "no approval, no Global pack in Release")
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
        XCTAssertTrue(unapproved.isDisjoint(with: pack.profiles.map(\.id)), "unapproved records are absent from Release")
        print("GLOBAL_RELEASE exposed=\(pack.profiles.count) unapproved=\(unapproved.count) individually=\(pack.profiles.filter { $0.review?.reviewMethod == .individuallyReviewed }.count) sample=\(pack.profiles.filter { $0.review?.reviewMethod == .sampleApproved }.count)")
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
