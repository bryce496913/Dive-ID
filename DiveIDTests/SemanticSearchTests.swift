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

    private struct CancelledRetriever: SpeciesCandidateRetrieving {
        func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
            throw CancellationError()
        }
    }

    private func pack() async throws -> OfflineIdentificationPack {
        try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource).loadPack(id: .caribbean)
    }

    private func index(
        documents: [SpeciesSearchDocument],
        pack: OfflineIdentificationPackMetadata,
        provider: FakeProvider,
        modelVersion: String? = nil,
        packVersion: Int? = nil,
        catalogueFingerprint: String? = nil,
        vectors: [[Float]]? = nil,
        tokenizerIdentifier: String? = nil,
        preprocessingIdentifier: String? = nil
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
                packVersion: packVersion ?? pack.packVersion,
                tokenizerIdentifier: tokenizerIdentifier ?? provider.tokenizerIdentifier,
                preprocessingIdentifier: preprocessingIdentifier ?? provider.preprocessingIdentifier
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

    func testValidationRejectsZeroVectorsAndUnknownSpecies() async throws {
        let pack = try await pack()
        let documents = Array(pack.profiles.prefix(2)).map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let provider = FakeProvider()
        let zero = try await index(documents: documents, pack: pack.metadata, provider: provider,
                                   vectors: [[0, 0, 0], [1, 0, 0]])
        XCTAssertThrowsError(try zero.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .invalidVector(speciesID: documents[0].speciesID))
        }
        let valid = try await index(documents: documents, pack: pack.metadata, provider: provider)
        let unknownID = UUID()
        let unknown = SpeciesEmbeddingIndex(metadata: valid.metadata, records: valid.records + [
            .init(speciesID: unknownID, documentFingerprint: "unknown", vector: [1, 0, 0])
        ])
        XCTAssertThrowsError(try unknown.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .unknownEmbedding(speciesID: unknownID))
        }
    }

    func testWordPieceContractAppliesPrefixTruncationMaskAndPadding() throws {
        let contract = SemanticModelArtifactContract(contractVersion: 1, modelIdentifier: "synthetic.mechanics", modelVersion: "1",
            embeddingDimension: 2, tokenizerIdentifier: "synthetic-vocab-1", preprocessingIdentifier: "synthetic-preprocess-1",
            vocabularyFile: "fixture.json", lowercase: true, stripAccents: true, maximumSequenceLength: 6, truncation: .end,
            clsToken: "[CLS]", separatorToken: "[SEP]", paddingToken: "[PAD]", unknownToken: "[UNK]",
            queryPrefix: "query: ", documentPrefix: "passage: ", inputIDsFeature: "ids", attentionMaskFeature: "mask",
            tokenTypeIDsFeature: nil, outputFeature: "hidden", pooling: .meanMasked, normalizeL2: true)
        let vocabulary = ["[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "query": 4, "cafe": 5, "fish": 6]
        let tokenizer = try WordPieceTokenizer(data: JSONEncoder().encode(vocabulary), contract: contract)
        let encoded = tokenizer.encode("CAFÉ fish")
        XCTAssertEqual(encoded.ids, [2, 4, 5, 6, 3, 0])
        XCTAssertEqual(encoded.mask, [1, 1, 1, 1, 1, 0])
    }

    func testCancellationDoesNotStartFallback() async throws {
        let retriever = FallbackSpeciesCandidateRetriever(primary: CancelledRetriever())
        do {
            _ = try await retriever.retrieve(query: "ignored", documents: [], limit: 1)
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
    }

    func testTokenizerAndPreprocessingMismatchesAreTyped() async throws {
        let pack = try await pack()
        let documents = Array(pack.profiles.prefix(2)).map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
        let provider = FakeProvider()
        let tokenizer = try await index(documents: documents, pack: pack.metadata, provider: provider, tokenizerIdentifier: "stale")
        XCTAssertThrowsError(try tokenizer.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .tokenizerMismatch)
        }
        let preprocessing = try await index(documents: documents, pack: pack.metadata, provider: provider, preprocessingIdentifier: "stale")
        XCTAssertThrowsError(try preprocessing.validate(provider: provider, pack: pack.metadata, documents: documents)) {
            XCTAssertEqual($0 as? SemanticIndexError, .preprocessingMismatch)
        }
    }

    func testExplicitExperimentalSelectionFallsBackWhenBundleAssetsAreMissing() async throws {
        let pack = try await pack()
        let diagnostics = SemanticDiagnosticsStore()
        let result = try await ConfiguredDescriptionSearchEngine(selection: .experimentalCoreML,
            bundle: TestResources.productionBundle, diagnostics: diagnostics)
            .search(description: "Spotted Eagle Ray", pack: pack)
        XCTAssertEqual(result.candidates.first?.profile.commonName, "Spotted Eagle Ray")
        let metric = await diagnostics.latest
        XCTAssertEqual(metric?.requestedEngine, .experimentalCoreML)
        XCTAssertEqual(metric?.actualEngine, .productionBM25)
        XCTAssertNotNil(metric?.fallbackReason)
    }
}
