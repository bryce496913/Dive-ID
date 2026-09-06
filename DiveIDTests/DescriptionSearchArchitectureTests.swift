import XCTest
@testable import DiveID

final class DescriptionSearchArchitectureTests: XCTestCase {
    private let queries = [
        "Large flat eagle ray with white spots and a long tail over sand in the Caribbean.",
        "Long silver fish with a pointed head, large teeth and dark spots cruising near a Caribbean reef.",
        "Beaked reef grazer with a squared looking head in the Caribbean."
    ]

    private func pack() async throws -> OfflineIdentificationPack {
        try await BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self)).loadPack(id: .caribbean)
    }

    func testStructuredEnginePreservesLegacyOrderingScoresAndEvidence() async throws {
        let pack = try await pack()
        let parser = LocalObservationParser()
        let ranker = LocalSpeciesRanker()
        let engine = StructuredDescriptionSearchEngine(parser: parser, ranker: ranker)

        for query in queries {
            let observation = await parser.parse(query)
            let legacy = try await ranker.rank(observation: observation, profiles: pack.profiles)
            let result = try await engine.search(description: query, pack: pack)

            XCTAssertEqual(result.candidates.map(\.profile.id), legacy.map(\.profile.id), query)
            XCTAssertEqual(result.candidates.map(\.score), legacy.map(\.score), query)
            XCTAssertEqual(result.candidates.map(\.rawScore), legacy.map(\.rawScore), query)
            XCTAssertEqual(result.candidates.map(\.matchedEvidence), legacy.map(\.matchedClues), query)
            XCTAssertEqual(result.candidates.map(\.conflictingEvidence), legacy.map(\.conflictingClues), query)
            XCTAssertEqual(result.candidates.first?.profile.id, legacy.first?.profile.id, query)
            XCTAssertLessThanOrEqual(result.candidates.count, 10)
        }
    }

    func testStructuredEnginePreservesRegionMismatchAnalysis() async throws {
        let pack = try await pack()
        let result = try await StructuredDescriptionSearchEngine().search(
            description: "Long colorful fish on an Indo-Pacific reef near Fiji.",
            pack: pack
        )
        XCTAssertEqual(result.queryAnalysis.packRegionCompatibility, .conflicting)
        let legacyObservation = await LocalObservationParser().parse("Long colorful fish on an Indo-Pacific reef near Fiji.")
        XCTAssertEqual(result.queryAnalysis.observedRegions, legacyObservation.regions)
    }

    func testDocumentsAreDeterministicCompleteAndNoiseFree() async throws {
        let pack = try await pack()
        let builder = SpeciesSearchDocumentBuilder()
        for profile in pack.profiles {
            let first = builder.document(from: profile, pack: pack.metadata)
            let second = builder.document(from: profile, pack: pack.metadata)
            XCTAssertEqual(first, second)
            XCTAssertEqual(first.fingerprint, second.fingerprint)
            XCTAssertEqual(first.speciesID, profile.id)
            XCTAssertEqual(first.packID, pack.metadata.id)
            XCTAssertFalse(first.combinedText.contains("|  |"))
            XCTAssertFalse(first.combinedText.hasPrefix("|"))
            XCTAssertFalse(first.combinedText.hasSuffix("|"))
            XCTAssertEqual(first.fingerprint.count, 64)
        }

        let parrotfish = try XCTUnwrap(pack.profiles.first { $0.commonName == "Stoplight Parrotfish" })
        let parrotfishText = builder.document(from: parrotfish, pack: pack.metadata).combinedText
        for evidence in ["beak", "head", "graz"] {
            XCTAssertTrue(parrotfishText.contains(evidence), evidence)
        }

        let ray = try XCTUnwrap(pack.profiles.first { $0.commonName == "Spotted Eagle Ray" })
        let rayDocument = builder.document(from: ray, pack: pack.metadata)
        for evidence in ["flat", "spot", "tail", "sand"] {
            XCTAssertTrue(rayDocument.combinedText.contains(evidence), evidence)
        }
        XCTAssertEqual(rayDocument.measurements.type, ray.measurements?.type)
        XCTAssertEqual(rayDocument.depthRange.minimumMeters, ray.minimumDepthMeters)
    }

    func testSearchableChangeChangesFingerprintAndVariantsRemainSourceBacked() async throws {
        let pack = try await pack()
        let profile = try XCTUnwrap(pack.profiles.first { !$0.appearanceVariants.isEmpty })
        let builder = SpeciesSearchDocumentBuilder()
        let original = builder.document(from: profile, pack: pack.metadata)

        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["summary"] = (object["summary"] as? String ?? "") + " source-change-marker"
        let changed = try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotEqual(original.fingerprint, builder.document(from: changed, pack: pack.metadata).fingerprint)

        for variant in profile.appearanceVariants {
            let sourceTerms = [variant.lifeStage.rawValue] + variant.colors + variant.markings
                + variant.bodyShapes + [variant.description] + variant.distinguishingFeatures
            for term in sourceTerms where !term.isEmpty {
                XCTAssertTrue(original.lifeStageText.contains(term.lowercased()))
            }
        }
    }

    func testBM25RetrievesRichTextPhrasesDeterministically() async throws {
        let pack = try await pack()
        let documents = pack.profiles.map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let retriever = BM25SpeciesCandidateRetriever()
        let cases = [
            ("fish with beak-like teeth grazing reef", "Stoplight Parrotfish"),
            ("long streamlined predator with large jaw", "Great Barracuda"),
            ("flat animal with white dots and whip-like tail", "Spotted Eagle Ray")
        ]

        for (query, expectedName) in cases {
            let first = try await retriever.retrieve(query: query, documents: documents, limit: 5)
            let second = try await retriever.retrieve(query: query, documents: documents, limit: 5)
            let expectedID = try XCTUnwrap(pack.profiles.first { $0.commonName == expectedName }?.id)
            XCTAssertTrue(first.contains { $0.speciesID == expectedID }, query)
            XCTAssertEqual(first, second, query)
            XCTAssertEqual(Set(first.map(\.speciesID)).count, first.count, query)
        }
    }

    func testBM25LimitExactNameAndVagueQueryBehavior() async throws {
        let pack = try await pack()
        let documents = pack.profiles.map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let retriever = BM25SpeciesCandidateRetriever()
        let exact = try await retriever.retrieve(query: "Spotted Eagle Ray", documents: documents, limit: 3)
        XCTAssertEqual(exact.first?.speciesID, pack.profiles.first { $0.commonName == "Spotted Eagle Ray" }?.id)
        XCTAssertEqual(exact.first?.evidence, .exactName)
        XCTAssertLessThanOrEqual(exact.count, 3)
        let vague = try await retriever.retrieve(query: "an animal in the", documents: documents, limit: 5)
        XCTAssertTrue(vague.isEmpty)
    }

    func testHybridSearchUsesRetrievedPoolAndStillCapsStructuredResults() async throws {
        let pack = try await pack()
        let result = try await HybridDescriptionSearchEngine(candidateLimit: 5).search(
            description: "flat animal with white dots and whip-like tail over sand",
            pack: pack
        )
        XCTAssertEqual(result.candidates.first?.profile.commonName, "Spotted Eagle Ray")
        XCTAssertLessThanOrEqual(result.candidates.count, 10)
        XCTAssertEqual(Set(result.candidates.map(\.profile.id)).count, result.candidates.count)
        XCTAssertFalse(result.candidates.first?.matchedEvidence.isEmpty ?? true)

        let vague = try await HybridDescriptionSearchEngine().search(description: "a fish on the reef", pack: pack)
        XCTAssertTrue(vague.candidates.allSatisfy { $0.informationLevel != .sufficient && $0.score <= 0.64 })
    }
}
