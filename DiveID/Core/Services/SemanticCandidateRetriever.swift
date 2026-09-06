import Foundation

/// Runtime boundary for a future, locally installed text encoder. Implementations
/// must not assume network access; a Core ML adapter is the intended next step.
protocol SemanticEmbeddingProviding: Sendable {
    var modelIdentifier: String { get }
    var modelVersion: String { get }
    var embeddingDimension: Int { get }
    var tokenizerIdentifier: String { get }
    var preprocessingIdentifier: String { get }

    func embedding(for text: String) async throws -> [Float]
    func embeddings(for texts: [String]) async throws -> [[Float]]
}

extension SemanticEmbeddingProviding {
    var tokenizerIdentifier: String { "unspecified" }
    var preprocessingIdentifier: String { "unspecified" }
}

extension SemanticEmbeddingProviding {
    func embeddings(for texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for text in texts { result.append(try await embedding(for: text)) }
        return result
    }
}

/// Values which bind an index to the encoder and exact catalogue used to build it.
struct SpeciesEmbeddingIndexMetadata: Codable, Hashable, Sendable {
    let modelIdentifier: String
    let modelVersion: String
    let embeddingDimension: Int
    let searchDocumentSchemaVersion: Int
    let documentFingerprint: String
    let packID: OfflineIdentificationPackID
    let packVersion: Int
    var tokenizerIdentifier: String = "unspecified"
    var preprocessingIdentifier: String = "unspecified"
    var indexFormatVersion: Int = 1
}

struct SpeciesEmbeddingRecord: Codable, Hashable, Sendable {
    let speciesID: UUID
    let documentFingerprint: String
    let vector: [Float]
}

struct SpeciesEmbeddingIndex: Codable, Hashable, Sendable {
    let metadata: SpeciesEmbeddingIndexMetadata
    let records: [SpeciesEmbeddingRecord]
}

enum SemanticIndexError: Error, Equatable {
    case modelIdentifierMismatch
    case modelVersionMismatch
    case embeddingDimensionMismatch
    case tokenizerMismatch
    case preprocessingMismatch
    case unsupportedIndexFormat
    case searchDocumentSchemaMismatch
    case documentFingerprintMismatch(speciesID: UUID?)
    case packIdentifierMismatch
    case packVersionMismatch
    case missingEmbedding(speciesID: UUID)
    case duplicateEmbedding(speciesID: UUID)
    case unknownEmbedding(speciesID: UUID)
    case invalidVector(speciesID: UUID)
}

extension SpeciesEmbeddingIndex {
    /// Rejects stale or partial indexes before any semantic result is returned.
    func validate(
        provider: any SemanticEmbeddingProviding,
        pack: OfflineIdentificationPackMetadata,
        documents: [SpeciesSearchDocument]
    ) throws {
        guard metadata.modelIdentifier == provider.modelIdentifier else { throw SemanticIndexError.modelIdentifierMismatch }
        guard metadata.modelVersion == provider.modelVersion else { throw SemanticIndexError.modelVersionMismatch }
        guard metadata.embeddingDimension == provider.embeddingDimension else { throw SemanticIndexError.embeddingDimensionMismatch }
        guard metadata.tokenizerIdentifier == provider.tokenizerIdentifier else { throw SemanticIndexError.tokenizerMismatch }
        guard metadata.preprocessingIdentifier == provider.preprocessingIdentifier else { throw SemanticIndexError.preprocessingMismatch }
        guard metadata.indexFormatVersion == 1 else { throw SemanticIndexError.unsupportedIndexFormat }
        guard metadata.searchDocumentSchemaVersion == SpeciesSearchDocument.schemaVersion else { throw SemanticIndexError.searchDocumentSchemaMismatch }
        guard metadata.packID == pack.id else { throw SemanticIndexError.packIdentifierMismatch }
        guard metadata.packVersion == pack.packVersion else { throw SemanticIndexError.packVersionMismatch }
        guard metadata.documentFingerprint == SpeciesSearchDocument.catalogueFingerprint(documents) else {
            throw SemanticIndexError.documentFingerprintMismatch(speciesID: nil)
        }

        var byID: [UUID: SpeciesEmbeddingRecord] = [:]
        let expectedIDs = Set(documents.map(\.speciesID))
        for record in records {
            guard byID.updateValue(record, forKey: record.speciesID) == nil else {
                throw SemanticIndexError.duplicateEmbedding(speciesID: record.speciesID)
            }
            guard expectedIDs.contains(record.speciesID) else { throw SemanticIndexError.unknownEmbedding(speciesID: record.speciesID) }
            guard !record.vector.isEmpty, record.vector.count == metadata.embeddingDimension,
                  record.vector.allSatisfy(\.isFinite), record.vector.contains(where: { $0 != 0 }) else {
                throw SemanticIndexError.invalidVector(speciesID: record.speciesID)
            }
        }
        for document in documents {
            guard let record = byID[document.speciesID] else { throw SemanticIndexError.missingEmbedding(speciesID: document.speciesID) }
            guard record.documentFingerprint == document.fingerprint else {
                throw SemanticIndexError.documentFingerprintMismatch(speciesID: document.speciesID)
            }
            guard record.vector.count == metadata.embeddingDimension, record.vector.allSatisfy(\.isFinite) else {
                throw SemanticIndexError.invalidVector(speciesID: document.speciesID)
            }
        }
    }
}

enum CosineSimilarity {
    /// Returns nil for mismatched dimensions, empty/zero vectors, or non-finite input.
    static func score(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0
        for (left, right) in zip(lhs, rhs) {
            let a = Double(left), b = Double(right)
            guard a.isFinite, b.isFinite else { return nil }
            dot += a * b
            lhsMagnitude += a * a
            rhsMagnitude += b * b
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return nil }
        let result = dot / sqrt(lhsMagnitude * rhsMagnitude)
        return result.isFinite ? max(-1, min(1, result)) : nil
    }
}

/// Retrieves only from a validated, precomputed offline index. It does not perform
/// biological scoring; `HybridDescriptionSearchEngine` remains the reranking seam.
struct SemanticCandidateRetriever: SpeciesCandidateRetrieving {
    let provider: any SemanticEmbeddingProviding
    let index: SpeciesEmbeddingIndex
    let packMetadata: OfflineIdentificationPackMetadata

    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        guard limit > 0, !documents.isEmpty else { return [] }
        try index.validate(provider: provider, pack: packMetadata, documents: documents)
        let queryVector = try await provider.embedding(for: query)
        guard queryVector.count == provider.embeddingDimension else { throw SemanticIndexError.embeddingDimensionMismatch }
        let records = Dictionary(uniqueKeysWithValues: index.records.map { ($0.speciesID, $0) })
        return try documents.map { document in
            guard let record = records[document.speciesID] else { throw SemanticIndexError.missingEmbedding(speciesID: document.speciesID) }
            guard let score = CosineSimilarity.score(queryVector, record.vector) else {
                throw SemanticIndexError.invalidVector(speciesID: document.speciesID)
            }
            return RetrievedSpeciesCandidate(speciesID: document.speciesID, retrievalScore: score, evidence: .semantic, matchedTerms: [])
        }.sorted {
            if $0.retrievalScore != $1.retrievalScore { return $0.retrievalScore > $1.retrievalScore }
            return $0.speciesID.uuidString < $1.speciesID.uuidString
        }.prefix(limit).map { $0 }
    }
}

/// Semantic failures are deliberately contained at retrieval time so description
/// identification remains available through the existing lexical/structured path.
struct FallbackSpeciesCandidateRetriever: SpeciesCandidateRetrieving {
    let primary: any SpeciesCandidateRetrieving
    let fallback: any SpeciesCandidateRetrieving

    init(primary: any SpeciesCandidateRetrieving, fallback: any SpeciesCandidateRetrieving = BM25SpeciesCandidateRetriever()) {
        self.primary = primary
        self.fallback = fallback
    }

    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        do {
            return try await primary.retrieve(query: query, documents: documents, limit: limit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await fallback.retrieve(query: query, documents: documents, limit: limit)
        }
    }
}
