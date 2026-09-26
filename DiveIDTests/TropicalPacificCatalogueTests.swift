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
            resourceResolutionMode: .bundleOnly,
            access: .experimentalDevelopment
        )
        let value = try await repository.loadPack(id: .tropicalPacific)
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.metadata.packVersion, 2)
        XCTAssertEqual(value.profiles.count, 384)
        XCTAssertEqual(value.metadata.speciesCount, value.profiles.count)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
    }

    func testDevelopmentAccessExplicitlyLoadsAllDraftPacificRecords() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle,
            resourceResolutionMode: .bundleOnly,
            access: .experimentalDevelopment
        )
        let metadata = try await repository.availablePacks().first { $0.id == .tropicalPacific }
        XCTAssertEqual(metadata?.includedRecordCount, 384)
        XCTAssertEqual(metadata?.humanReviewedRecordCount, 0)
        XCTAssertEqual(metadata?.publicationEligibleRecordCount, 0)
        XCTAssertEqual(metadata?.isExperimental, true)
        let value = try await repository.loadPack(id: .tropicalPacific)
        XCTAssertEqual(value.profiles.count, 384)
        XCTAssertTrue(value.profiles.allSatisfy { $0.review?.status == .draft })
    }

    func testPublicationStatusLabelsFailClosedAndDescribeDraftMixedAndApprovedPacks() throws {
        var metadata = try pack().metadata
        metadata.includedRecordCount = nil
        metadata.humanReviewedRecordCount = nil
        metadata.publicationEligibleRecordCount = nil
        XCTAssertTrue(metadata.isExperimental)
        XCTAssertEqual(metadata.publicationStatusText, "Review accounting unavailable — not approved for publication")

        metadata.includedRecordCount = 384
        metadata.humanReviewedRecordCount = 0
        metadata.publicationEligibleRecordCount = 0
        XCTAssertEqual(metadata.publicationStatusText, "384 records available — 0 approved and 384 draft")

        metadata.humanReviewedRecordCount = 12
        metadata.publicationEligibleRecordCount = 10
        XCTAssertEqual(metadata.publicationStatusText, "384 records available — 10 approved and 374 draft")

        metadata.humanReviewedRecordCount = 384
        metadata.publicationEligibleRecordCount = 384
        XCTAssertFalse(metadata.isExperimental)
        XCTAssertEqual(metadata.publicationStatusText, "All 384 available records approved for publication")
    }

    func testPublicationAccessExcludesDraftPackAndReturnsClearDiagnosticWhenRequested() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle,
            resourceResolutionMode: .bundleOnly,
            access: .publication
        )
        let available = try await repository.availablePacks()
        XCTAssertFalse(available.contains { $0.id == .tropicalPacific })
        do {
            _ = try await repository.loadPack(id: .tropicalPacific)
            XCTFail("Publication access exposed draft-only Pacific records")
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .publicationUnavailable)
            XCTAssertEqual(failure.catalogError, .publicationUnavailable)
        }
    }

    func testVerifiedPromotionRequiresTraceableHumanReviewEvidence() throws {
        let value = try pack()
        var promoted = try XCTUnwrap(value.profiles.first)
        promoted.review = RecordReview(status: .verified, reviewerNotes: "Checked", reviewDate: Date(), verifiedBy: "Human reviewer")
        promoted.dataSources[0].citationReference = nil
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([promoted])) {
            XCTAssertEqual($0 as? LocalCatalogError, .unverifiedRecord)
        }
    }

#if DIVEID_XCODE_HOSTED_TEST
    func testProductionRepositoryLoadsTropicalPacificFromBuiltApplicationBundle() async throws {
        // This test exists only in the Xcode-hosted iOS test target. A missing app
        // resource is a test failure, never a signal that the test is "not hosted".
        let repository = BundleMarineSpeciesCatalogRepository(bundle: .main, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
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

    func testParserRecognizesControlledTermsBeforeSentencePunctuation() async {
        let observation = await LocalObservationParser().parse("Fish with spots. Resting on sand.")

        XCTAssertTrue(observation.markings.contains("spots"))
        XCTAssertTrue(observation.habitats.contains("sand"))
        XCTAssertTrue(observation.behaviors.contains("resting"))
    }

    func testParserDoesNotInventWhiteColorFromPaleLightness() async {
        let pale = await LocalObservationParser().parse("pale animal")
        let white = await LocalObservationParser().parse("white animal")

        XCTAssertFalse(pale.colors.contains("white"))
        XCTAssertTrue(white.colors.contains("white"))
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

    func testSourceCorrectionAndUnresolvedRetrievalTrace() async throws {
        let value = try pack()
        let cases = try diverDescriptions().filter { ["pacific-v1-fire-dartfish", "pacific-v1-cockatoo-waspfish"].contains($0.id) }
        let builder = SpeciesSearchDocumentBuilder()
        let documents = value.profiles.map { builder.document(from: $0, pack: value.metadata) }
        for item in cases {
            let observation = await LocalObservationParser().parse(item.description)
            let retrieved = try await BM25SpeciesCandidateRetriever().retrieve(query: item.description, documents: documents, limit: documents.count)
            let expected = try XCTUnwrap(retrieved.first { item.acceptedSpeciesIDs.contains($0.speciesID) })
            let retrievalRank = try XCTUnwrap(retrieved.firstIndex(of: expected)).advanced(by: 1)
            let profile = try XCTUnwrap(value.profiles.first { $0.id == expected.speciesID })
            let isolated = try await LocalSpeciesRanker().rank(input: .init(
                description: item.description,
                observation: observation,
                candidates: [.init(speciesID: profile.id, profile: profile, retrieval: .init(
                    source: expected.evidence, scoreKind: expected.scoreKind, score: expected.retrievalScore,
                    rank: retrievalRank, evidence: expected.matchedTerms
                ))]
            )).first
            let displayed = try await HybridDescriptionSearchEngine().search(description: item.description, pack: value)
            let displayedRank = displayed.candidates.firstIndex { $0.profile.id == profile.id }.map { $0 + 1 }
            if item.id == "pacific-v1-fire-dartfish" {
                XCTAssertEqual(profile.colors, ["brown", "red", "white", "yellow"])
                XCTAssertEqual(profile.behaviors, ["hovering", "solitary"])
                XCTAssertLessThanOrEqual(retrievalRank, 50)
                XCTAssertEqual(displayedRank, 5)
            } else {
                XCTAssertGreaterThan(retrievalRank, 50)
                XCTAssertNil(displayedRank, "Unsupported Cockatoo Waspfish traits must not be invented to satisfy the fixture")
            }
            print("PACIFIC_FAILURE_TRACE id=\(item.id) categories=\(observation.categories.sorted()) colors=\(observation.colors.sorted()) markings=\(observation.markings.sorted()) shapes=\(observation.bodyShapes.sorted()) habitats=\(observation.habitats.sorted()) behaviors=\(observation.behaviors.sorted()) retrievalRank=\(retrievalRank) retrievalScore=\(expected.retrievalScore) terms=\(expected.matchedTerms) survives50=\(retrievalRank <= 50) rawScore=\(String(describing: isolated?.rawScore)) support=\(isolated?.matchedClues ?? []) conflicts=\(isolated?.conflictingClues ?? []) eligible=\(isolated != nil) displayedRank=\(String(describing: displayedRank))")
        }
    }
}
