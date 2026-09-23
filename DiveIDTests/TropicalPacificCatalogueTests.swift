import Foundation
import XCTest
@testable import DiveID

final class TropicalPacificCatalogueTests: XCTestCase {
    private struct DiverDescriptionCase: Decodable {
        let id: String
        let description: String
        let selectedPackID: OfflineIdentificationPackID
        let expectedSpeciesIDs: [UUID]
        let acceptableSpeciesIDs: [UUID]
        let maximumAcceptableRank: Int?
        let rationale: String
        let sources: [String]

        var acceptedSpeciesIDs: Set<UUID> { Set(expectedSpeciesIDs + acceptableSpeciesIDs) }
        var expectsNoMatch: Bool { expectedSpeciesIDs.isEmpty && acceptableSpeciesIDs.isEmpty }
    }

    private struct PositiveEvaluationFailure: Error {
        let caseIDs: [String]
    }

    private struct PacificFixtureCatalogRepository: MarineSpeciesCatalogRepository {
        let pack: OfflineIdentificationPack

        func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }

        func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
            guard id == pack.metadata.id else { throw LocalIdentificationError.catalogUnavailable }
            return pack
        }
    }

    private struct EmptyDescriptionSearchEngine: DescriptionSearching {
        func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
            DescriptionSearchResult(
                candidates: [],
                queryAnalysis: .init(observedRegions: [], packRegionCompatibility: .unspecified),
                retrievedSpeciesIDs: [],
                retrievalLimit: 50
            )
        }
    }

    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("DiveID/Resources/IdentificationPacks/TropicalPacific")

    private func pack() throws -> OfflineIdentificationPack {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: root.appendingPathComponent("PackManifest.json")))
        let profiles = try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: root.appendingPathComponent("Creatures.json")))
        return .init(metadata: metadata, profiles: profiles)
    }

    private func diverDescriptions() throws -> [DiverDescriptionCase] {
        try JSONDecoder().decode(
            [DiverDescriptionCase].self,
            from: Data(contentsOf: TestResources.fixture(named: "TropicalPacificDiverDescriptions.v1"))
        )
    }

    private func evaluate(
        _ cases: [DiverDescriptionCase],
        searchEngine: any DescriptionSearching,
        engineName: String
    ) async throws -> [(id: String, rank: Int?)] {
        let value = try pack()
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.metadata.packVersion, 2)
        XCTAssertEqual(value.metadata.speciesCount, 384)
        XCTAssertEqual(value.profiles.count, value.metadata.speciesCount)

        let repository = PacificFixtureCatalogRepository(pack: value)
        let service = LocalMarineLifeIdentificationService(catalogRepository: repository, searchEngine: searchEngine)
        var measurements: [(id: String, rank: Int?)] = []
        var positiveFailures: [String] = []

        for item in cases {
            let request = IdentificationRequest(
                source: .description(item.description),
                context: .init(region: item.selectedPackID)
            )
            let matches = try await service.identify(request: request, processedPhoto: nil)
            let rank = matches.firstIndex { item.acceptedSpeciesIDs.contains($0.species.id) }.map { $0 + 1 }
            measurements.append((item.id, rank))

            if item.expectsNoMatch {
                XCTAssertTrue(matches.isEmpty, "\(item.id) unexpectedly returned \(matches.map(\.species.commonName))")
            } else if rank == nil || rank! > item.maximumAcceptableRank! {
                positiveFailures.append(item.id)
            }

            XCTAssertTrue(matches.allSatisfy { (0...1).contains($0.score) }, "\(item.id) returned confidence outside 0...1")
            print("PACIFIC_DESCRIPTION_CASE engine=\(engineName) id=\(item.id) expected=\(item.expectedSpeciesIDs) maxRank=\(String(describing: item.maximumAcceptableRank)) measuredRank=\(String(describing: rank)) returned=\(matches.map { $0.species.id })")
        }

        if !positiveFailures.isEmpty { throw PositiveEvaluationFailure(caseIDs: positiveFailures) }
        return measurements
    }

    func testGeneratedPackPreservesTraceabilityAndHasNoLicensedArtworkClaims() throws {
        let value = try pack()
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.profiles.count, 384)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
        XCTAssertTrue(value.profiles.allSatisfy { $0.bundledImage == nil && $0.imageAssetName == nil })
        XCTAssertTrue(value.profiles.allSatisfy { $0.review?.status == .draft && !($0.dataSources.first?.stableSourceID ?? "").isEmpty })
        XCTAssertTrue(value.profiles.allSatisfy { $0.minimumSizeCentimeters == nil && $0.measurements?.typicalObservedMinimumCentimeters == nil })
    }

    func testImportedFishCategoryReachesStructuredRankingEvidence() async throws {
        let value = try pack()
        let butterflyfish = try XCTUnwrap(value.profiles.first { $0.id == UUID(uuidString: "963e8b58-2834-5f5c-a668-af3ade719497") })
        XCTAssertEqual(butterflyfish.categories, ["fish"])

        let observation = await LocalObservationParser().parse("yellow fish on a reef")
        let ranked = try await LocalSpeciesRanker().rank(observation: observation, profiles: [butterflyfish])
        let match = try XCTUnwrap(ranked.first)
        XCTAssertTrue(match.matchedClues.contains("fish"))
        XCTAssertGreaterThanOrEqual(match.rawScore, LocalRankingWeights().category)
    }

    func testProductionRepositoryLoadsTropicalPacificFromExplicitPortableBundle() async throws {
        // Bundle-only is deliberate: SwiftPM must package the catalogue rather than
        // allowing this portable assertion to pass through a checkout fallback.
        let repository = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle,
            resourceResolutionMode: .bundleOnly
        )
        let value = try await repository.loadPack(id: .tropicalPacific)
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.metadata.packVersion, 2)
        XCTAssertEqual(value.profiles.count, 384)
        XCTAssertEqual(value.metadata.speciesCount, value.profiles.count)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
    }

#if DIVEID_XCODE_HOSTED_TEST
    func testProductionRepositoryLoadsTropicalPacificFromBuiltApplicationBundle() async throws {
        // This test exists only in the Xcode-hosted iOS test target. A missing app
        // resource is a test failure, never a signal that the test is "not hosted".
        let repository = BundleMarineSpeciesCatalogRepository(bundle: .main, resourceResolutionMode: .bundleOnly)
        let value = try await repository.loadPack(id: .tropicalPacific)
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.metadata.packVersion, 2)
        XCTAssertEqual(value.metadata.speciesCount, 384)
        XCTAssertEqual(value.profiles.count, value.metadata.speciesCount)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
    }
#endif

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
                XCTAssertTrue(result.candidates.isEmpty)
            }
        }
    }

    func testVersionedDiverDescriptionsThroughProductionIdentificationService() async throws {
        let cases = try diverDescriptions()
        XCTAssertEqual(cases.count, 7)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        XCTAssertTrue(cases.allSatisfy { $0.selectedPackID == .tropicalPacific })
        XCTAssertTrue(cases.allSatisfy { !$0.rationale.isEmpty && !$0.sources.isEmpty })
        XCTAssertTrue(cases.contains { $0.description.lowercased().contains("fish") })
        XCTAssertTrue(cases.contains { $0.id == "pacific-v1-frog-no-match" && $0.expectsNoMatch })
        XCTAssertTrue(cases.filter { !$0.expectsNoMatch }.allSatisfy { $0.maximumAcceptableRank != nil })

        _ = try await evaluate(
            cases,
            searchEngine: HybridDescriptionSearchEngine(),
            engineName: "production-bm25-plus-biological-ranking"
        )
    }

    func testPositiveEvaluatorRejectsAnEngineThatAlwaysReturnsEmptyResults() async throws {
        let positiveCases = try diverDescriptions().filter { !$0.expectsNoMatch }
        XCTAssertFalse(positiveCases.isEmpty)
        do {
            _ = try await evaluate(
                positiveCases,
                searchEngine: EmptyDescriptionSearchEngine(),
                engineName: "controlled-always-empty"
            )
            XCTFail("The positive-case evaluator accepted an engine that returned no results")
        } catch let failure as PositiveEvaluationFailure {
            XCTAssertEqual(Set(failure.caseIDs), Set(positiveCases.map(\.id)))
        }
    }
}
