import XCTest
@testable import DiveID
#if canImport(CoreML)
import CoreML
#endif

final class SemanticSearchTests: XCTestCase {
    private struct TokenizerFixture: Decodable {
        struct FixtureCase: Decodable {
            let name: String
            let text: String
            let document: Bool
            let truncation: SemanticModelArtifactContract.Truncation
            let inputIDs: [Int32]
            let attentionMask: [Int32]
        }
        let vocabulary: [String: Int]
        let contract: SemanticModelArtifactContract
        let cases: [FixtureCase]
    }

    private func semanticContract(
        maximumSequenceLength: Int = 6,
        embeddingDimension: Int = 2,
        truncation: SemanticModelArtifactContract.Truncation = .end,
        pooling: SemanticModelArtifactContract.Pooling = .meanMasked
    ) -> SemanticModelArtifactContract {
        SemanticModelArtifactContract(contractVersion: 1, modelIdentifier: "synthetic.mechanics", modelVersion: "1",
            embeddingDimension: embeddingDimension, tokenizerIdentifier: "synthetic-vocab-1", preprocessingIdentifier: "synthetic-preprocess-1",
            vocabularyFile: "fixture.json", lowercase: true, stripAccents: true, maximumSequenceLength: maximumSequenceLength, truncation: truncation,
            clsToken: "[CLS]", separatorToken: "[SEP]", paddingToken: "[PAD]", unknownToken: "[UNK]",
            queryPrefix: "query: ", documentPrefix: "passage: ", inputIDsFeature: "ids", attentionMaskFeature: "mask",
            tokenTypeIDsFeature: nil, outputFeature: "hidden", pooling: pooling, normalizeL2: true)
    }
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
        let contract = semanticContract()
        let vocabulary = ["[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "query": 4, "cafe": 5, "fish": 6]
        let tokenizer = try WordPieceTokenizer(data: JSONEncoder().encode(vocabulary), contract: contract)
        let encoded = tokenizer.encode("CAFÉ fish")
        XCTAssertEqual(encoded.ids, [2, 4, 5, 6, 3, 0])
        XCTAssertEqual(encoded.mask, [1, 1, 1, 1, 1, 0])
    }

    func testWordPieceTokenizerExactlyMatchesSharedPythonParityFixture() throws {
        let url = try TestResources.fixture(named: "TokenizerParity.v1")
        let fixture = try JSONDecoder().decode(TokenizerFixture.self, from: Data(contentsOf: url))
        let vocabularyData = try JSONEncoder().encode(fixture.vocabulary)
        for fixtureCase in fixture.cases {
            let base = fixture.contract
            let contract = SemanticModelArtifactContract(contractVersion: base.contractVersion,
                modelIdentifier: base.modelIdentifier, modelVersion: base.modelVersion,
                embeddingDimension: base.embeddingDimension, tokenizerIdentifier: base.tokenizerIdentifier,
                preprocessingIdentifier: base.preprocessingIdentifier, vocabularyFile: base.vocabularyFile,
                lowercase: base.lowercase, stripAccents: base.stripAccents,
                maximumSequenceLength: base.maximumSequenceLength, truncation: fixtureCase.truncation,
                clsToken: base.clsToken, separatorToken: base.separatorToken, paddingToken: base.paddingToken,
                unknownToken: base.unknownToken, queryPrefix: base.queryPrefix, documentPrefix: base.documentPrefix,
                inputIDsFeature: base.inputIDsFeature, attentionMaskFeature: base.attentionMaskFeature,
                tokenTypeIDsFeature: base.tokenTypeIDsFeature, outputFeature: base.outputFeature,
                pooling: base.pooling, normalizeL2: base.normalizeL2)
            let result = try WordPieceTokenizer(data: vocabularyData, contract: contract)
                .encode(fixtureCase.text, document: fixtureCase.document)
            XCTAssertEqual(result.ids, fixtureCase.inputIDs, fixtureCase.name)
            XCTAssertEqual(result.mask, fixtureCase.attentionMask, fixtureCase.name)
        }
    }

#if canImport(CoreML)
    func testExactCoreMLOutputShapesAndPooling() throws {
        func set(_ array: MLMultiArray, _ indices: [Int], _ value: Float) {
            array[indices.map { NSNumber(value: $0) }] = NSNumber(value: value)
        }
        let vectorContract = semanticContract(embeddingDimension: 2, pooling: .modelOutput)
        let vector = try MLMultiArray(shape: [NSNumber(value: 1), NSNumber(value: 2)], dataType: .float32)
        set(vector, [0, 0], 3); set(vector, [0, 1], 4)
        XCTAssertEqual(try CoreMLSemanticEmbeddingProvider.pool(vector, mask: [], contract: vectorContract), [0.6, 0.8])

        let clsContract = semanticContract(maximumSequenceLength: 3, embeddingDimension: 2, pooling: .cls)
        let tokens = try MLMultiArray(shape: [1, 3, 2].map { NSNumber(value: $0) }, dataType: .float16)
        set(tokens, [0, 0, 0], 3); set(tokens, [0, 0, 1], 4)
        set(tokens, [0, 1, 0], 100); set(tokens, [0, 1, 1], 100)
        XCTAssertEqual(try CoreMLSemanticEmbeddingProvider.pool(tokens, mask: [1, 1, 0], contract: clsContract), [0.6, 0.8])

        let meanContract = semanticContract(maximumSequenceLength: 3, embeddingDimension: 2, pooling: .meanMasked)
        let mean = try MLMultiArray(shape: [1, 3, 2].map { NSNumber(value: $0) }, dataType: .float32)
        set(mean, [0, 0, 0], 1); set(mean, [0, 0, 1], 0)
        set(mean, [0, 1, 0], 0); set(mean, [0, 1, 1], 1)
        set(mean, [0, 2, 0], 20); set(mean, [0, 2, 1], 20)
        let rootHalf = Float(1 / sqrt(2.0))
        let pooled = try CoreMLSemanticEmbeddingProvider.pool(mean, mask: [1, 1, 0], contract: meanContract)
        XCTAssertEqual(pooled[0], rootHalf, accuracy: 0.0001)
        XCTAssertEqual(pooled[1], rootHalf, accuracy: 0.0001)
    }

    func testCoreMLOutputRejectsTransposeWrongDimensionsRankAndType() throws {
        let contract = semanticContract(maximumSequenceLength: 3, embeddingDimension: 2)
        for shape in [[1, 2, 3], [1, 4, 2], [1, 3, 4], [3, 2], [1, 1, 3, 2]] {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
            XCTAssertThrowsError(try CoreMLSemanticEmbeddingProvider.pool(array, mask: [1, 1, 1], contract: contract)) {
                XCTAssertEqual($0 as? SemanticArtifactDiagnostic, .invalidModelOutputShape)
            }
        }
        let unsupported = try MLMultiArray(shape: [1, 3, 2].map { NSNumber(value: $0) }, dataType: .double)
        XCTAssertThrowsError(try CoreMLSemanticEmbeddingProvider.pool(unsupported, mask: [1, 1, 1], contract: contract)) {
            XCTAssertEqual($0 as? SemanticArtifactDiagnostic, .unsupportedModelOutputDataType)
        }
    }
#endif

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
