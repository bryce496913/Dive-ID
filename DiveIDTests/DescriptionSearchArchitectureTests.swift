import XCTest
@testable import DiveID

final class DescriptionSearchArchitectureTests: XCTestCase {
    // Synthetic contract fixtures isolate fusion behavior; they do not measure
    // the quality of a real embedding model.
    private func syntheticCopy(_ profile: LocalSpeciesProfile, id: UUID, name: String, regions: [String]? = nil) throws -> LocalSpeciesProfile {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        object["id"] = id.uuidString
        object["commonName"] = name
        if let regions { object["regions"] = regions }
        return try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func semantic(_ score: Double, rank: Int) -> SpeciesRetrievalSignal {
        SpeciesRetrievalSignal(source: .semantic, scoreKind: .cosineSimilarity, score: score, rank: rank, evidence: [])
    }
    private let queries = [
        "Large flat eagle ray with white spots and a long tail over sand in the Caribbean.",
        "Long silver fish with a pointed head, large teeth and dark spots cruising near a Caribbean reef.",
        "Beaked reef grazer with a squared looking head in the Caribbean."
    ]

    private func pack() async throws -> OfflineIdentificationPack {
        try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle).loadPack(id: .caribbean)
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

    func testSyntheticRetrievalRelevanceChangesOrderWithEqualStructuredEvidence() async throws {
        let loadedPack = try await pack()
        let base = try XCTUnwrap(loadedPack.profiles.first)
        let alpha = try syntheticCopy(base, id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, name: "Alpha")
        let beta = try syntheticCopy(base, id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, name: "Beta")
        let observation = await LocalObservationParser().parse("sleek creature drifting quietly offshore")
        let ranker = LocalSpeciesRanker()
        let first = try await ranker.rank(input: .init(description: "sleek creature drifting quietly offshore", observation: observation, candidates: [
            .init(speciesID: alpha.id, profile: alpha, retrieval: semantic(0.95, rank: 1)),
            .init(speciesID: beta.id, profile: beta, retrieval: semantic(0.70, rank: 2))
        ]))
        let reversed = try await ranker.rank(input: .init(description: "sleek creature drifting quietly offshore", observation: observation, candidates: [
            .init(speciesID: alpha.id, profile: alpha, retrieval: semantic(0.70, rank: 2)),
            .init(speciesID: beta.id, profile: beta, retrieval: semantic(0.95, rank: 1))
        ]))
        XCTAssertEqual(first.map(\.profile.id), [alpha.id, beta.id])
        XCTAssertEqual(reversed.map(\.profile.id), [beta.id, alpha.id])
        XCTAssertEqual(first[0].rawScore, first[1].rawScore)
    }

    func testSyntheticSemanticParaphraseIsProvisionalButNotConfident() async throws {
        let loadedPack = try await pack()
        let profile = try XCTUnwrap(loadedPack.profiles.first)
        let description = "sleek creature drifting quietly offshore"
        let observation = await LocalObservationParser().parse(description)
        let result = try await LocalSpeciesRanker().rank(input: .init(description: description, observation: observation, candidates: [
            .init(speciesID: profile.id, profile: profile, retrieval: semantic(0.92, rank: 1))
        ]))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.informationLevel, .limited)
        XCTAssertLessThanOrEqual(result.first?.score ?? 1, 0.64)
        XCTAssertEqual(result.first?.matchedClues, ["catalogue description similarity"])

        let vague = await LocalObservationParser().parse("a fish on the reef")
        let vagueResult = try await LocalSpeciesRanker().rank(input: .init(description: "a fish on the reef", observation: vague, candidates: [
            .init(speciesID: profile.id, profile: profile, retrieval: semantic(1, rank: 1))
        ]))
        XCTAssertTrue(vagueResult.allSatisfy { $0.informationLevel != .sufficient && $0.score <= 0.64 })
    }

    func testSyntheticConflictsDuplicatesAndTiesRemainDeterministic() async throws {
        let loadedPack = try await pack()
        let base = try XCTUnwrap(loadedPack.profiles.first)
        let compatible = try syntheticCopy(base, id: UUID(uuidString: "00000000-0000-0000-0000-000000000201")!, name: "Beta", regions: ["caribbean"])
        let conflicting = try syntheticCopy(base, id: UUID(uuidString: "00000000-0000-0000-0000-000000000202")!, name: "Alpha", regions: ["indo-pacific"])
        let description = "blue fish on a coral reef in the Caribbean"
        let observation = await LocalObservationParser().parse(description)
        let result = try await LocalSpeciesRanker().rank(input: .init(description: description, observation: observation, candidates: [
            .init(speciesID: conflicting.id, profile: conflicting, retrieval: semantic(0.8, rank: 1)),
            .init(speciesID: compatible.id, profile: compatible, retrieval: semantic(0.8, rank: 2)),
            .init(speciesID: compatible.id, profile: compatible, retrieval: semantic(0.8, rank: 3))
        ]))
        XCTAssertEqual(Set(result.map(\.profile.id)).count, result.count)
        XCTAssertEqual(result.first?.profile.id, compatible.id)
        XCTAssertTrue(result.first { $0.profile.id == conflicting.id }?.conflictingClues.contains("geographic range") == true)

        let tiedObservation = await LocalObservationParser().parse("sleek creature drifting quietly offshore")
        let tied = try await LocalSpeciesRanker().rank(input: .init(description: "sleek creature drifting quietly offshore", observation: tiedObservation, candidates: [
            .init(speciesID: compatible.id, profile: compatible, retrieval: semantic(0.8, rank: 2)),
            .init(speciesID: conflicting.id, profile: conflicting, retrieval: semantic(0.8, rank: 1))
        ]))
        XCTAssertEqual(tied.map(\.profile.commonName), ["Alpha", "Beta"])
    }
}
