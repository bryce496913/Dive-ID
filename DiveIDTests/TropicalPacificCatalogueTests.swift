import Foundation
import XCTest
@testable import DiveID

final class TropicalPacificCatalogueTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("DiveID/Resources/IdentificationPacks/TropicalPacific")

    private func pack() throws -> OfflineIdentificationPack {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: root.appendingPathComponent("PackManifest.json")))
        let profiles = try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: root.appendingPathComponent("Creatures.json")))
        return .init(metadata: metadata, profiles: profiles)
    }

    func testGeneratedPackPreservesTraceabilityAndHasNoLicensedArtworkClaims() throws {
        let value = try pack()
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.profiles.count, 40)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
        XCTAssertTrue(value.profiles.allSatisfy { $0.bundledImage == nil && $0.imageAssetName == nil })
        XCTAssertTrue(value.profiles.allSatisfy { $0.review?.status == .draft && !($0.dataSources.first?.stableSourceID ?? "").isEmpty })
        XCTAssertTrue(value.profiles.allSatisfy { $0.minimumSizeCentimeters == nil && $0.measurements?.typicalObservedMinimumCentimeters == nil })
    }

    func testSearchDiagnosticsSeparateRetrievalMissFromRankerRejection() async throws {
        let value = try pack()
        let noRetrieval = try await HybridDescriptionSearchEngine(candidateLimit: 10).search(description: "quasar locomotive", pack: value)
        XCTAssertEqual(noRetrieval.diagnostics.disposition, .noRetrievedCandidates)
        XCTAssertEqual(noRetrieval.diagnostics.retrievedCandidateCount, 0)

        let rejected = try await HybridDescriptionSearchEngine(candidateLimit: 10).search(description: "yellow", pack: value)
        XCTAssertGreaterThan(rejected.diagnostics.retrievedCandidateCount, 0)
        XCTAssertEqual(rejected.diagnostics.disposition, .allCandidatesRejectedByRanker)
        XCTAssertEqual(rejected.diagnostics.rankedCandidateCount, 0)
    }

    func testVariedDescriptionsAndCandidateRecallAtRequestedCutoffs() async throws {
        let value = try pack()
        let positives: [(String, UUID)] = [
            ("bright yellow butterflyfish with one large black oval spot on its back", UUID(uuidString: "963e8b58-2834-5f5c-a668-af3ade719497")!),
            ("white bannerfish in a big school with two black bands and a long dorsal filament", UUID(uuidString: "f5591466-ba33-5c7a-b4dd-e4a3130c6a23")!),
            ("yellow angelfish with blue around its eye and blue edge on the gill cover", UUID(uuidString: "d57e2c37-6d4a-50f3-add6-871de33cc8e0")!),
            ("dark surgeonfish covered in white spots with a white bar behind the eye", UUID(uuidString: "4f2f87f1-11d4-5d2c-8e62-c1d8cbbcaec5")!)
        ]
        let ambiguous = ["yellow fish around a coral reef", "silver fish with a faint bar swimming in a group"]
        let noMatches = ["purple freshwater trout under lily pads", "air-breathing seal with whiskers"]
        for limit in [10, 25, 50] {
            var hits = 0
            let engine = HybridDescriptionSearchEngine(candidateLimit: limit)
            for item in positives {
                let result = try await engine.search(description: item.0, pack: value)
                if result.retrievedSpeciesIDs.contains(item.1) { hits += 1 }
            }
            XCTAssertEqual(hits, positives.count, "candidate recall@\(limit) should retain all source-backed positives")
            print("Tropical Pacific candidate recall@\(limit): \(hits)/\(positives.count)")
            for description in ambiguous {
                let result = try await engine.search(description: description, pack: value)
                XCTAssertFalse(result.retrievedSpeciesIDs.isEmpty)
            }
            for description in noMatches {
                let result = try await engine.search(description: description, pack: value)
                XCTAssertEqual(result.diagnostics.disposition, .noRetrievedCandidates)
            }
        }
    }
}
