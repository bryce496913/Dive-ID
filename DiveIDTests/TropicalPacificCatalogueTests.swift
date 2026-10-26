import Foundation
import XCTest
@testable import DiveID

final class TropicalPacificCatalogueTests: XCTestCase {
    func testSharedCatalogueValidationFixturesAgreeWithSwiftDecodeAndDomainValidation() throws {
        let data = try Data(contentsOf: TestResources.fixture(named: "CatalogueValidationCases"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let valid = try XCTUnwrap(document["validRecord"] as? [String: Any])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profile = try decoder.decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: valid))
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([profile]))

        for item in try XCTUnwrap(document["invalid"] as? [[String: Any]]) {
            let name = try XCTUnwrap(item["name"] as? String)
            let field = try XCTUnwrap(item["field"] as? String)
            var candidate = valid
            candidate[field] = item["value"]
            let candidateData = try JSONSerialization.data(withJSONObject: candidate)
            do {
                let decoded = try decoder.decode(LocalSpeciesProfile.self, from: candidateData)
                XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([decoded]), name)
            } catch is DecodingError {
                // Type, required/null, nested, and enum mismatches are rejected before domain validation.
            }
        }
    }

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
        XCTAssertEqual(value.metadata.packVersion, 3)
        XCTAssertEqual(value.metadata.speciesCount, 1000)
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
        XCTAssertEqual(value.profiles.count, 1000)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
        XCTAssertTrue(value.profiles.allSatisfy { $0.bundledImage == nil && $0.imageAssetName == nil })
        XCTAssertTrue(value.profiles.allSatisfy { !($0.dataSources.first?.stableSourceID ?? "").isEmpty })
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
        XCTAssertEqual(value.metadata.packVersion, 3)
        XCTAssertEqual(value.profiles.count, 1000)
        XCTAssertEqual(value.metadata.speciesCount, value.profiles.count)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: value))
    }

    func testDevelopmentAccessPreservesCurrentReviewAccounting() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle,
            resourceResolutionMode: .bundleOnly,
            access: .experimentalDevelopment
        )
        for id in [OfflineIdentificationPackID.caribbean, .tropicalPacific] {
            // Retired regions are not listed; opening one still checks its accounting.
            let value = try await repository.loadPack(id: id)
            let metadata = value.metadata
            let reviewed = value.profiles.filter { $0.review?.status == .sourceChecked || $0.review?.status == .verified }.count
            let approved = value.profiles.filter { $0.review?.status == .verified }.count
            XCTAssertEqual(metadata.includedRecordCount, value.profiles.count)
            XCTAssertEqual(metadata.humanReviewedRecordCount, reviewed)
            XCTAssertEqual(metadata.publicationEligibleRecordCount, approved)
            XCTAssertEqual(metadata.isExperimental, approved != value.profiles.count)
        }
    }

    func testPublicationStatusLabelsFailClosedAndDescribeDraftMixedAndApprovedPacks() throws {
        var metadata = try pack().metadata
        metadata.includedRecordCount = nil
        metadata.humanReviewedRecordCount = nil
        metadata.publicationEligibleRecordCount = nil
        XCTAssertTrue(metadata.isExperimental)
        XCTAssertEqual(metadata.publicationStatusText, "Review accounting unavailable — not approved for publication")

        metadata.speciesCount = 384 // Dedicated mixed-status accounting fixture.
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

    func testBundledPublicationAvailabilityTracksActualVerifiedRecords() async throws {
        // Generated from validated human decisions; Python checks this oracle against
        // every overlay and fingerprint, independently of catalogue status flags.
        let expectedURL = try TestResources.fixture(named: "PublicationApprovedIDs")
        let expectedIDs = try JSONDecoder().decode([String: [UUID]].self, from: Data(contentsOf: expectedURL))
        let publication = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication)
        let development = BundleMarineSpeciesCatalogRepository(
            bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let available = try await publication.availablePacks()
        for id in [OfflineIdentificationPackID.caribbean, .tropicalPacific, .global] {
            let full = try await development.loadPack(id: id)
            let approved = full.profiles.filter { $0.review?.status == .verified && !$0.categories.isEmpty }
            let expected = Set(try XCTUnwrap(expectedIDs[id.rawValue]))
            XCTAssertEqual(Set(approved.map(\.id)), expected)
            let drafts = Set(full.profiles.filter { $0.review?.status == .draft }.map(\.id))
            // Caribbean and Tropical Pacific are retired dive regions: Release never opens them,
            // whatever their approvals (their species are in Global and its regions).
            let releaseOpens = RegionCatalogRegistry.bundled.definition(for: id)?.isListed == true && !approved.isEmpty
            XCTAssertEqual(available.contains { $0.id == id }, releaseOpens)
            if !releaseOpens {
                do {
                    _ = try await publication.loadPack(id: id)
                    XCTFail("Publication exposed a retired pack or one with no approved records")
                } catch let failure as CatalogueLoadFailure {
                    XCTAssertEqual(failure.code, .publicationUnavailable)
                    XCTAssertEqual(failure.catalogError, .publicationUnavailable)
                }
            } else {
                let published = try await publication.loadPack(id: id)
                XCTAssertEqual(Set(published.profiles.map(\.id)), expected)
                XCTAssertTrue(published.profiles.allSatisfy { $0.review?.status == .verified })
                XCTAssertTrue(drafts.isDisjoint(with: published.profiles.map(\.id)))
                XCTAssertEqual(published.metadata.availableRecordCount, approved.count)
                XCTAssertEqual(published.metadata.includedRecordCount, full.profiles.count)
                XCTAssertEqual(published.metadata.approvedRecordCount, approved.count)
                let listed = try XCTUnwrap(available.first { $0.id == id })
                XCTAssertEqual(listed.publicationStatusText, published.metadata.publicationStatusText)
            }
            print("PUBLICATION_GATE pack=\(id.rawValue) approved=\(approved.count) available=\(releaseOpens)")
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
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundlePackageType"] as? String, "APPL", "This packaging assertion requires the actual application test host")
        let repository = BundleMarineSpeciesCatalogRepository(bundle: .main, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let value = try await repository.loadPack(id: .tropicalPacific)
        XCTAssertEqual(value.metadata.id, .tropicalPacific)
        XCTAssertEqual(value.metadata.packVersion, 3)
        XCTAssertEqual(value.metadata.speciesCount, 1000)
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

    func testSourceCorrectionsSurviveRetrievalAndBiologicalRanking() async throws {
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
                XCTAssertEqual(displayedRank, 1)
            } else {
                XCTAssertTrue(profile.colors.contains("brown"))
                XCTAssertEqual(profile.bodyShapes, ["compressed"])
                XCTAssertEqual(profile.finAndSpineClues, ["tall dorsal fin", "sail shaped dorsal fin"])
                XCTAssertLessThanOrEqual(retrievalRank, 50, "Source-backed record must reach the candidate pool")
                XCTAssertTrue(displayed.retrievedSpeciesIDs.contains(profile.id), "Retrieval miss, before biological ranking")
                XCTAssertNotNil(isolated, "Biological ranker rejected the retrieved record")
                XCTAssertEqual(isolated?.rawScore, 11)
                XCTAssertTrue(isolated?.matchedClues.contains("sail shaped dorsal fin") == true)
                XCTAssertNotNil(displayedRank, "Eligible candidate was lost during competitive ranking")
                XCTAssertLessThanOrEqual(try XCTUnwrap(displayedRank), try XCTUnwrap(item.maximumAcceptableRank))
            }
            print("PACIFIC_SOURCE_TRACE id=\(item.id) categories=\(observation.categories.sorted()) colors=\(observation.colors.sorted()) markings=\(observation.markings.sorted()) shapes=\(observation.bodyShapes.sorted()) habitats=\(observation.habitats.sorted()) behaviors=\(observation.behaviors.sorted()) retrievalRank=\(retrievalRank) retrievalScore=\(expected.retrievalScore) terms=\(expected.matchedTerms) survives50=\(retrievalRank <= 50) rawScore=\(String(describing: isolated?.rawScore)) support=\(isolated?.matchedClues ?? []) conflicts=\(isolated?.conflictingClues ?? []) eligible=\(isolated != nil) displayedRank=\(String(describing: displayedRank))")
        }
    }
    func testExpansionScoreTrace() async throws {
        guard let destination = ProcessInfo.processInfo.environment["DIVEID_EXPANSION_TRACE"] else { return }
        let full = try pack()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let additions = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Data/TropicalPacific/TropicalPacificExpansion616.draft.json"))) as! [[String: Any]]
        let added = Set(additions.compactMap { UUID(uuidString: $0["id"] as! String) })
        let v05 = try JSONSerialization.jsonObject(with: Data(contentsOf: TestResources.fixture(named: "V05Development.v2"))) as! [String: Any]
        let surgeon = (v05["cases"] as! [[String: Any]]).first { $0["id"] as? String == "v05-14-paraphrase" }!
        let fire = try diverDescriptions().first { $0.id == "pacific-v1-fire-dartfish" }!
        var queries: [(String, String, UUID)] = [(fire.id, fire.description, fire.expectedSpeciesIDs[0]), (surgeon["id"] as! String, surgeon["description"] as! String, UUID(uuidString: (surgeon["expectedSpeciesIDs"] as! [String])[0])!)]
        let extra = (v05["cases"] as! [[String: Any]]).first { $0["id"] as? String == "v05-09-paraphrase" }!
        queries.append((extra["id"] as! String, extra["description"] as! String, UUID(uuidString: (extra["expectedSpeciesIDs"] as! [String])[0])!))
        var traces: [[String: Any]] = []
        for (label, profiles) in [("preExpansion", full.profiles.filter { !added.contains($0.id) }), ("expanded", full.profiles)] {
            let documents = profiles.map { SpeciesSearchDocumentBuilder().document(from: $0, pack: full.metadata) }
            for (caseID, query, expectedID) in queries {
                let observation = await LocalObservationParser().parse(query)
                let retrieved = try await BM25SpeciesCandidateRetriever().retrieve(query: query, documents: documents, limit: documents.count)
                let indexed = documents.map { BM25SpeciesCandidateRetriever.terms($0.combinedText) }
                let averageLength = Double(indexed.reduce(0) { $0 + $1.count }) / Double(indexed.count)
                let documentFrequency = indexed.flatMap { Set($0) }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                var rows: [[String: Any]] = []
                var hybrid: [(UUID, Double)] = []; var structured: [(UUID, Double)] = []
                for profile in profiles {
                    let index = retrieved.firstIndex { $0.speciesID == profile.id }
                    let hit = index.map { retrieved[$0] }
                    let signal = hit.map { SpeciesRetrievalSignal(source: $0.evidence, scoreKind: $0.scoreKind, score: $0.retrievalScore, rank: index! + 1, evidence: $0.matchedTerms) }
                    let single = try await LocalSpeciesRanker().rank(input: .init(description: query, observation: observation, candidates: [.init(speciesID: profile.id, profile: profile, retrieval: signal)])).first
                    let plain = try await LocalSpeciesRanker().rank(observation: observation, profiles: [profile]).first
                    if let single, let index, index < 50 { hybrid.append((profile.id, single.orderingScore)) }
                    if let plain { structured.append((profile.id, plain.orderingScore)) }
                    rows.append(["id": profile.id.uuidString, "name": profile.commonName, "added": added.contains(profile.id), "retrievalRank": index.map { $0 + 1 } as Any? ?? NSNull(), "bm25": hit?.retrievalScore as Any? ?? NSNull(), "matchedTerms": hit?.matchedTerms ?? [], "eligible": single != nil, "raw": single?.rawScore as Any? ?? NSNull(), "ordering": single?.orderingScore as Any? ?? NSNull(), "structuredOrdering": plain?.orderingScore as Any? ?? NSNull(), "support": single?.matchedClues ?? [], "conflicts": single?.conflictingClues ?? [], "document": documents.first { $0.speciesID == profile.id }!.combinedText])
                }
                func ordered(_ values: [(UUID, Double)]) -> [UUID] {
                    values.sorted { a, b in
                        if a.1 != b.1 { return a.1 > b.1 }
                        let an = profiles.first { $0.id == a.0 }!.commonName; let bn = profiles.first { $0.id == b.0 }!.commonName
                        return an == bn ? a.0.uuidString < b.0.uuidString : an < bn
                    }.map { $0.0 }
                }
                for index in rows.indices {
                    let terms = indexed[index]
                    let frequencies = Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +)
                    let matchedTerms = rows[index]["matchedTerms"] as! [String]
                    var termEvidence: [[String: Any]] = []
                    let corpusCount = Double(documents.count)
                    let lengthRatio = Double(terms.count) / averageLength
                    let lengthPenalty = 1.2 * (0.25 + 0.75 * lengthRatio)
                    for term in matchedTerms {
                        let frequency = Double(frequencies[term, default: 0])
                        let df = Double(documentFrequency[term, default: 0])
                        let inverseRatio = (corpusCount - df + 0.5) / (df + 0.5)
                        let idf = log(1.0 + inverseRatio)
                        let contribution = idf * frequency * 2.2 / (frequency + lengthPenalty)
                        let evidence: [String: Any] = ["term": term, "frequency": frequency, "documentFrequency": df, "idf": idf, "contribution": contribution]
                        termEvidence.append(evidence)
                    }
                    rows[index]["bm25Terms"] = termEvidence
                    rows[index]["documentLength"] = terms.count
                    rows[index]["averageDocumentLength"] = averageLength
                }
                let h = ordered(hybrid); let st = ordered(structured)
                let selected = Set(h.prefix(12)).union(st.prefix(12)).union(retrieved.prefix(12).map(\.speciesID)).union([expectedID])
                for index in rows.indices {
                    let id = UUID(uuidString: rows[index]["id"] as! String)!
                    rows[index]["hybridRank"] = h.firstIndex(of: id).map { $0 + 1 } as Any? ?? NSNull()
                    rows[index]["structuredRank"] = st.firstIndex(of: id).map { $0 + 1 } as Any? ?? NSNull()
                }
                traces.append(["catalogue":label,"count":profiles.count,"fingerprint":SpeciesSearchDocument.catalogueFingerprint(documents),"caseID":caseID,"query":query,"expectedID":expectedID.uuidString,"tokens":observation.tokens.sorted(),"appearanceRelationships":observation.appearanceRelationships.sorted(),"colorEvidenceGroups":observation.colorEvidenceGroups.map { $0.sorted() },"colors":observation.colors.sorted(),"markings":observation.markings.sorted(),"shapes":observation.bodyShapes.sorted(),"habitats":observation.habitats.sorted(),"behaviors":observation.behaviors.sorted(),"categories":observation.categories.sorted(),"candidates":rows.filter { selected.contains(UUID(uuidString:$0["id"] as! String)!) }])
            }
        }
        try JSONSerialization.data(withJSONObject: traces, options: [.prettyPrinted,.sortedKeys]).write(to: URL(fileURLWithPath: destination))
    }

}
