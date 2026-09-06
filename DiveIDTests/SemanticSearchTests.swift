import XCTest
@testable import DiveID

final class SemanticSearchTests: XCTestCase {
    private struct FakeProvider: SemanticEmbeddingProviding {
        var modelIdentifier = "test.fake"
        var modelVersion = "1"
        var embeddingDimension = 3
        var shouldFail = false

        func embedding(for text: String) async throws -> [Float] {
            if shouldFail { throw TestError.modelUnavailable }
            let bytes = Array(text.utf8)
            return (0..<embeddingDimension).map { offset in
                Float(bytes.enumerated().filter { $0.offset % embeddingDimension == offset }.reduce(0) { $0 + Int($1.element) } % 101)
            }
        }
    }

    private enum TestError: Error { case modelUnavailable }

    private func pack() async throws -> OfflineIdentificationPack {
        try await BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self)).loadPack(id: .caribbean)
    }

    private func index(
        documents: [SpeciesSearchDocument],
        pack: OfflineIdentificationPackMetadata,
        provider: FakeProvider,
        modelVersion: String? = nil,
        packVersion: Int? = nil,
        catalogueFingerprint: String? = nil,
        vectors: [[Float]]? = nil
    ) async throws -> SpeciesEmbeddingIndex {
        let generated = try await provider.embeddings(for: documents.map(\.combinedText))
        return SpeciesEmbeddingIndex(
            metadata: SpeciesEmbeddingIndexMetadata(
                modelIdentifier: provider.modelIdentifier,
                modelVersion: modelVersion ?? provider.modelVersion,
                embeddingDimension: provider.embeddingDimension,
                searchDocumentSchemaVersion: SpeciesSearchDocument.schemaVersion,
                documentFingerprint: catalogueFingerprint ?? SpeciesSearchDocument.catalogueFingerprint(documents),
                packID: pack.id,
                packVersion: packVersion ?? pack.packVersion
            ),
            records: zip(documents, vectors ?? generated).map {
                SpeciesEmbeddingRecord(speciesID: $0.speciesID, documentFingerprint: $0.fingerprint, vector: $1)
            }
        )
    }

    func testFakeProviderIsDeterministicAndSupportsBatching() async throws {
        let provider = FakeProvider()
        let first = try await provider.embedding(for: "striped reef fish")
        let second = try await provider.embedding(for: "striped reef fish")
        XCTAssertEqual(first, second)
        let batch = try await provider.embeddings(for: ["one", "two"])
        let expected = [try await provider.embedding(for: "one"), try await provider.embedding(for: "two")]
        XCTAssertEqual(batch, expected)
    }

    func testCosineSimilarityOrderingAndUnsafeInputs() {
        let exact = CosineSimilarity.score([1, 0], [1, 0])
        let diagonal = CosineSimilarity.score([1, 0], [1, 1])
        XCTAssertGreaterThan(try XCTUnwrap(exact), try XCTUnwrap(diagonal))
        XCTAssertNil(CosineSimilarity.score([1], [1, 2]))
        XCTAssertNil(CosineSimilarity.score([0, 0], [1, 2]))
        XCTAssertNil(CosineSimilarity.score([Float.nan], [1]))
    }

    func testCompatibilityRejectsStaleFingerprintWrongModelAndWrongPackVersions() async throws {
        let pack = try await pack()
        let documents = pack.profiles.map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let provider = FakeProvider()

        let stale = try await index(documents: documents, pack: pack.metadata, provider: provider, catalogueFingerprint: "stale")
        XCTAssertThrowsError(try stale.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .documentFingerprintMismatch(speciesID: nil))
        }
        let wrongModel = try await index(documents: documents, pack: pack.metadata, provider: provider, modelVersion: "old")
        XCTAssertThrowsError(try wrongModel.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .modelVersionMismatch)
        }
        let wrongPack = try await index(documents: documents, pack: pack.metadata, provider: provider, packVersion: pack.metadata.packVersion - 1)
        XCTAssertThrowsError(try wrongPack.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .packVersionMismatch)
        }
    }

    func testSemanticRetrieverOrdersSyntheticCandidates() async throws {
        let pack = try await pack()
        let documents = Array(pack.profiles.prefix(3)).map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let provider = FakeProvider(embeddingDimension: 2)
        let query = "horizontal"
        let queryVector = try await provider.embedding(for: query)
        let perpendicular: [Float] = [-queryVector[1], queryVector[0]]
        let vectors = [perpendicular, queryVector, queryVector.map { -$0 }]
        let semanticIndex = try await index(documents: documents, pack: pack.metadata, provider: provider, vectors: vectors)
        let result = try await SemanticCandidateRetriever(provider: provider, index: semanticIndex, packMetadata: pack.metadata)
            .retrieve(query: query, documents: documents, limit: 3)
        XCTAssertEqual(result.map(\.speciesID), [documents[1].speciesID, documents[0].speciesID, documents[2].speciesID])
        XCTAssertTrue(result.allSatisfy { $0.evidence == .semantic })
    }

    func testSemanticModelFailureFallsBackToLexicalRetriever() async throws {
        let pack = try await pack()
        let documents = pack.profiles.map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let working = FakeProvider()
        let semanticIndex = try await index(documents: documents, pack: pack.metadata, provider: working)
        let failing = FakeProvider(shouldFail: true)
        let primary = SemanticCandidateRetriever(provider: failing, index: semanticIndex, packMetadata: pack.metadata)
        let retriever = FallbackSpeciesCandidateRetriever(primary: primary)
        let result = try await retriever.retrieve(query: "Spotted Eagle Ray", documents: documents, limit: 3)
        XCTAssertEqual(result.first?.speciesID, pack.profiles.first { $0.commonName == "Spotted Eagle Ray" }?.id)
        XCTAssertEqual(result.first?.evidence, .exactName)
    }
}
