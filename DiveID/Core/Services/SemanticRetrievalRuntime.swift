import Foundation

enum DescriptionRetrievalEngine: String, Sendable {
    case productionBM25, experimentalCoreML

    /// This constant is deliberately machine-tested. Experimental availability is not
    /// evidence of production approval; promotion additionally requires the external,
    /// fingerprint-bound production-readiness gate.
    static let productionDefault: Self = .productionBM25
}

struct SemanticRetrievalMetrics: Sendable {
    let requestedEngine: DescriptionRetrievalEngine
    let actualEngine: DescriptionRetrievalEngine
    let modelIdentity: String?
    let tokenizerIdentity: String?
    let preprocessingIdentity: String?
    let packIdentity: String
    let fallbackReason: SemanticArtifactDiagnostic?
    let modelCacheHit: Bool
    let indexCacheHit: Bool
    let queryCacheHit: Bool
    let loadMilliseconds: Double
    let embeddingMilliseconds: Double
    let retrievalMilliseconds: Double
    let totalMilliseconds: Double
}

protocol SemanticDiagnosticsReporting: Sendable { func record(_ metrics: SemanticRetrievalMetrics) async }

actor SemanticDiagnosticsStore: SemanticDiagnosticsReporting {
    private(set) var latest: SemanticRetrievalMetrics?
    func record(_ metrics: SemanticRetrievalMetrics) { latest = metrics }
}

#if DEBUG
/// Debug-only, query-free evidence of which retrieval engine actually served a search.
/// Keeping this type out of release builds prevents technical telemetry and UI from
/// accidentally becoming a production data-collection surface.
actor DebugSemanticDiagnosticsReporter: SemanticDiagnosticsReporting {
    nonisolated let updates: AsyncStream<SemanticRetrievalMetrics>
    private let continuation: AsyncStream<SemanticRetrievalMetrics>.Continuation
    private(set) var latest: SemanticRetrievalMetrics?

    init() {
        var captured: AsyncStream<SemanticRetrievalMetrics>.Continuation?
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { captured = $0 }
        continuation = captured!
    }

    func record(_ metrics: SemanticRetrievalMetrics) {
        latest = metrics
        continuation.yield(metrics)
    }

    deinit { continuation.finish() }
}
#endif

struct SemanticArtifactLocations: Sendable {
    let contractURL: URL
    let compiledModelURL: URL
    let vocabularyURL: URL
    let indexURL: URL

    static func bundled(packID: OfflineIdentificationPackID, bundle: Bundle = .main) throws -> Self {
        let stem = "Semantic-\(packID.rawValue)"
        guard let contract = bundle.url(forResource: stem, withExtension: "contract.json") else { throw SemanticArtifactDiagnostic.missingContract(stem) }
        guard let model = bundle.url(forResource: stem, withExtension: "mlmodelc") else { throw SemanticArtifactDiagnostic.missingModel(stem) }
        guard let vocabulary = bundle.url(forResource: stem, withExtension: "vocab.json") else { throw SemanticArtifactDiagnostic.missingTokenizer(stem) }
        guard let index = bundle.url(forResource: stem, withExtension: "index.json") else { throw SemanticArtifactDiagnostic.missingIndex(stem) }
        return Self(contractURL: contract, compiledModelURL: model, vocabularyURL: vocabulary, indexURL: index)
    }
}

/// Owns lazy artifacts, validation, and the bounded query LRU. Actor isolation prevents
/// concurrent first searches from loading or validating an immutable artifact twice.
actor SemanticRetrievalRuntime {
    private struct Loaded {
        let provider: any SemanticEmbeddingProviding
        let index: SpeciesEmbeddingIndex
        let identity: String
    }
    private var loaded: [String: Loaded] = [:]
    private var loading: [String: Task<Loaded, Error>] = [:]
    private var validated = Set<String>()
    private var queryVectors: [String: [Float]] = [:]
    private var queryLRU: [String] = []
    private let queryCapacity: Int
    private let injectedArtifacts: Loaded?

    init(queryCapacity: Int = 32) {
        self.queryCapacity = max(0, queryCapacity)
        injectedArtifacts = nil
    }

    /// Test seam for proving diagnostics around a valid semantic execution without
    /// requiring a platform Core ML binary. Production always uses the initializer above.
    init(queryCapacity: Int = 32, provider: any SemanticEmbeddingProviding, index: SpeciesEmbeddingIndex) {
        self.queryCapacity = max(0, queryCapacity)
        injectedArtifacts = Loaded(provider: provider, index: index,
                                   identity: "\(provider.modelIdentifier):\(provider.modelVersion):\(index.metadata.documentFingerprint)")
    }

    func retrieve(locations: SemanticArtifactLocations, pack: OfflineIdentificationPackMetadata,
                  documents: [SpeciesSearchDocument], query: String, limit: Int) async throws
        -> (candidates: [RetrievedSpeciesCandidate], modelHit: Bool, indexHit: Bool, queryHit: Bool, loadMS: Double, embeddingMS: Double, retrievalMS: Double, loaded: (String, String, String)) {
        try Task.checkCancellation()
        let loadStart = ContinuousClock.now
        try Self.requireArtifact(locations.contractURL, or: .missingContract(locations.contractURL.lastPathComponent))
        try Self.requireArtifact(locations.compiledModelURL, or: .missingModel(locations.compiledModelURL.lastPathComponent))
        try Self.requireArtifact(locations.vocabularyURL, or: .missingTokenizer(locations.vocabularyURL.lastPathComponent))
        try Self.requireArtifact(locations.indexURL, or: .missingIndex(locations.indexURL.lastPathComponent))
        let artifactKey = try [locations.contractURL, locations.compiledModelURL,
                               locations.vocabularyURL, locations.indexURL].map(Self.fileIdentity).joined(separator: "|")
        let wasLoaded = loaded[artifactKey] != nil
        let artifacts: Loaded
        if let injectedArtifacts { artifacts = injectedArtifacts }
        else if let cached = loaded[artifactKey] { artifacts = cached } else {
            let task: Task<Loaded, Error>
            if let inFlight = loading[artifactKey] { task = inFlight }
            else {
                task = Task { try await self.load(locations) }
                loading[artifactKey] = task
            }
            do { artifacts = try await task.value }
            catch { loading[artifactKey] = nil; throw error }
            try Task.checkCancellation()
            loaded[artifactKey] = artifacts
            loading[artifactKey] = nil
        }
        let validationKey = artifacts.identity + ":" + SpeciesSearchDocument.catalogueFingerprint(documents)
        let indexHit = validated.contains(validationKey)
        if !indexHit {
            do { try artifacts.index.validate(provider: artifacts.provider, pack: pack, documents: documents) }
            catch let error as SemanticIndexError { throw SemanticArtifactDiagnostic.incompatibleIndex(error) }
            validated.insert(validationKey)
        }
        let loadMS = Self.milliseconds(since: loadStart)
        try Task.checkCancellation()
        let queryKey = artifacts.identity + ":" + StableQueryFingerprint.digest(query)
        let queryHit = queryVectors[queryKey] != nil
        let embeddingStart = ContinuousClock.now
        let queryVector: [Float]
        if let cached = queryVectors[queryKey] { queryVector = cached; touch(queryKey) }
        else {
            queryVector = try await artifacts.provider.embedding(for: query)
            try Task.checkCancellation()
            guard queryVector.count == artifacts.provider.embeddingDimension,
                  queryVector.allSatisfy(\.isFinite), queryVector.contains(where: { $0 != 0 }) else {
                throw SemanticArtifactDiagnostic.invalidModelOutput
            }
            insert(queryVector, key: queryKey)
        }
        let embeddingMS = Self.milliseconds(since: embeddingStart)
        let retrievalStart = ContinuousClock.now
        let records = Dictionary(uniqueKeysWithValues: artifacts.index.records.map { ($0.speciesID, $0.vector) })
        var candidates: [RetrievedSpeciesCandidate] = []
        candidates.reserveCapacity(documents.count)
        for document in documents {
            try Task.checkCancellation()
            guard let vector = records[document.speciesID], let score = CosineSimilarity.score(queryVector, vector) else {
                throw SemanticArtifactDiagnostic.incompatibleIndex(.invalidVector(speciesID: document.speciesID))
            }
            candidates.append(RetrievedSpeciesCandidate(speciesID: document.speciesID, retrievalScore: score,
                                                         evidence: .semantic, matchedTerms: []))
        }
        candidates.sort {
            if $0.retrievalScore != $1.retrievalScore { return $0.retrievalScore > $1.retrievalScore }
            return $0.speciesID.uuidString < $1.speciesID.uuidString
        }
        return (Array(candidates.prefix(max(0, limit))), wasLoaded, indexHit, queryHit, loadMS, embeddingMS,
                Self.milliseconds(since: retrievalStart), (artifacts.provider.modelIdentifier + ":" + artifacts.provider.modelVersion,
                artifacts.provider.tokenizerIdentifier, artifacts.provider.preprocessingIdentifier))
    }

    private func load(_ locations: SemanticArtifactLocations) async throws -> Loaded {
        let (contractData, vocabularyData, indexData) = try await Task.detached(priority: .userInitiated) {
            try (Data(contentsOf: locations.contractURL), Data(contentsOf: locations.vocabularyURL), Data(contentsOf: locations.indexURL))
        }.value
        guard let contract = try? JSONDecoder().decode(SemanticModelArtifactContract.self, from: contractData) else { throw SemanticArtifactDiagnostic.malformedContract }
        try contract.validate()
        guard let index = try? JSONDecoder().decode(SpeciesEmbeddingIndex.self, from: indexData) else { throw SemanticArtifactDiagnostic.malformedIndex }
#if canImport(CoreML)
        let provider = try await CoreMLSemanticEmbeddingProvider.load(compiledModelURL: locations.compiledModelURL, contract: contract, vocabularyData: vocabularyData)
        return Loaded(provider: provider, index: index, identity: contract.cacheIdentity + ":" + index.metadata.documentFingerprint)
#else
        _ = vocabularyData; _ = index
        throw SemanticArtifactDiagnostic.coreMLUnavailable
#endif
    }

    private func insert(_ vector: [Float], key: String) {
        guard queryCapacity > 0 else { return }
        queryVectors[key] = vector; touch(key)
        while queryLRU.count > queryCapacity { queryVectors.removeValue(forKey: queryLRU.removeFirst()) }
    }
    private func touch(_ key: String) { queryLRU.removeAll { $0 == key }; queryLRU.append(key) }
    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    private static func fileIdentity(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return "\(url.path):\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
    }
    private static func requireArtifact(_ url: URL, or diagnostic: SemanticArtifactDiagnostic) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw diagnostic }
    }
}

struct ExperimentalSemanticRetriever: SpeciesCandidateRetrieving {
    let pack: OfflineIdentificationPackMetadata
    let locations: SemanticArtifactLocations
    let runtime: SemanticRetrievalRuntime
    let fallback: any SpeciesCandidateRetrieving
    let diagnostics: (any SemanticDiagnosticsReporting)?

    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        let total = ContinuousClock.now
        do {
            let result = try await runtime.retrieve(locations: locations, pack: pack, documents: documents, query: query, limit: limit)
            await diagnostics?.record(.init(requestedEngine: .experimentalCoreML, actualEngine: .experimentalCoreML,
                modelIdentity: result.loaded.0, tokenizerIdentity: result.loaded.1, preprocessingIdentity: result.loaded.2,
                packIdentity: "\(pack.id.rawValue):\(pack.packVersion)", fallbackReason: nil,
                modelCacheHit: result.modelHit, indexCacheHit: result.indexHit, queryCacheHit: result.queryHit,
                loadMilliseconds: result.loadMS, embeddingMilliseconds: result.embeddingMS,
                retrievalMilliseconds: result.retrievalMS, totalMilliseconds: Self.ms(total)))
            return result.candidates
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // Never attach arbitrary error text: model errors can echo their input.
            let reason = (error as? SemanticArtifactDiagnostic) ?? .semanticRuntimeFailure
            let fallbackStart = ContinuousClock.now
            let candidates = try await fallback.retrieve(query: query, documents: documents, limit: limit)
            await diagnostics?.record(.init(requestedEngine: .experimentalCoreML, actualEngine: .productionBM25,
                modelIdentity: nil, tokenizerIdentity: nil, preprocessingIdentity: nil,
                packIdentity: "\(pack.id.rawValue):\(pack.packVersion)", fallbackReason: reason,
                modelCacheHit: false, indexCacheHit: false, queryCacheHit: false, loadMilliseconds: 0,
                embeddingMilliseconds: 0, retrievalMilliseconds: Self.ms(fallbackStart), totalMilliseconds: Self.ms(total)))
            return candidates
        }
    }
    private static func ms(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}

private enum StableQueryFingerprint {
    static func digest(_ value: String) -> String {
        // Queries never enter diagnostics; this process-local key is deliberately one-way enough for cache lookup.
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return String(hash, radix: 16)
    }
}
