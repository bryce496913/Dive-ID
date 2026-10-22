import Foundation

protocol SpeciesCandidateRetrieving: Sendable {
    func retrieve(
        query: String,
        documents: [SpeciesSearchDocument],
        limit: Int
    ) async throws -> [RetrievedSpeciesCandidate]
}

struct RetrievedSpeciesCandidate: Sendable, Equatable {
    enum Evidence: String, Sendable {
        case exactName
        case fullText
        case semantic
    }

    let speciesID: UUID
    let retrievalScore: Double
    let evidence: Evidence
    let matchedTerms: [String]
}

/// The scale of a retrieval score. Scores on different scales are never added
/// directly by the ranker.
enum RetrievalScoreKind: Sendable, Equatable {
    case bm25
    case cosineSimilarity
}

extension RetrievedSpeciesCandidate {
    var scoreKind: RetrievalScoreKind {
        evidence == .semantic ? .cosineSimilarity : .bm25
    }
}

/// A small, dependency-free BM25 retriever. It deliberately indexes the complete
/// canonical document, including deduplicated explicit appearance relationships.
struct BM25SpeciesCandidateRetriever: SpeciesCandidateRetrieving {
    let saturation: Double
    let lengthNormalization: Double

    init(saturation: Double = 1.2, lengthNormalization: Double = 0.75) {
        self.saturation = saturation
        self.lengthNormalization = lengthNormalization
    }

    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        try await retrieve(query: query, index: BM25Index(documents: documents), limit: limit)
    }

    /// Scores against a prebuilt index. The arithmetic is exactly the per-query
    /// computation it replaces, so scores and ordering are unchanged.
    func retrieve(query: String, index: BM25Index, limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        guard limit > 0, !index.entries.isEmpty else { return [] }
        let queryTerms = Self.terms(query).filter { !Self.stopWords.contains($0) }
        guard !queryTerms.isEmpty else { return [] }
        let uniqueQueryTerms = Array(Set(queryTerms)).sorted()
        let normalizedQuery = Self.normalizedPhrase(query)
        let count = Double(index.entries.count)
        let averageLength = index.averageLength
        return index.entries.compactMap { entry -> RetrievedSpeciesCandidate? in
            var score = 0.0
            var matches: [String] = []
            for term in uniqueQueryTerms {
                guard let frequency = entry.termFrequencies[term], frequency > 0 else { continue }
                let df = Double(index.documentFrequency[term, default: 0])
                let inverseFrequency = log(1 + (count - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                let denominator = tf + saturation * (1 - lengthNormalization + lengthNormalization * Double(entry.length) / averageLength)
                score += inverseFrequency * (tf * (saturation + 1)) / denominator
                matches.append(term)
            }

            let exactName = entry.normalizedNames.contains(normalizedQuery)
            if exactName { score += 100 }
            guard score > 0 else { return nil }
            return RetrievedSpeciesCandidate(
                speciesID: entry.speciesID,
                retrievalScore: score,
                evidence: exactName ? .exactName : .fullText,
                matchedTerms: matches
            )
        }.sorted { left, right in
            if left.retrievalScore != right.retrievalScore { return left.retrievalScore > right.retrievalScore }
            return left.speciesID.uuidString < right.speciesID.uuidString
        }.prefix(limit).map { $0 }
    }

    static func terms(_ text: String) -> [String] {
        var seenMorphology = Set<String>()
        let canonical = Set(MorphologyVocabulary.patterns.map { $0.0.replacingOccurrences(of: " ", with: "") })
        let words = MorphologyVocabulary.scopedText(text).split { !$0.isLetter && !$0.isNumber }.map {
            LocalObservationParser.singular(String($0))
        }.filter { !$0.isEmpty && (!canonical.contains($0) || seenMorphology.insert($0).inserted) }
        return words + AppearanceEvidenceVocabulary.appearanceRelationships(in: text).sorted().map { "appearance" + $0.filter(\.isLetter) }
    }

    static func normalizedPhrase(_ text: String) -> String { terms(text).joined(separator: " ") }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "animal", "at", "by", "in", "is", "it", "near", "of", "on", "the", "to", "with"
    ]
}

/// Per-document BM25 statistics, built once per catalogue content and reused by every
/// query: term frequencies, lengths, the average length, document frequencies and the
/// normalized names used for exact-name matches. Immutable, so safe to share.
struct BM25Index: Sendable {
    struct Entry: Sendable {
        let speciesID: UUID
        let termFrequencies: [String: Int]
        let length: Int
        let normalizedNames: [String]
    }

    let entries: [Entry]
    let averageLength: Double
    let documentFrequency: [String: Int]

    init(documents: [SpeciesSearchDocument]) {
        var documentFrequency: [String: Int] = [:]
        entries = documents.map { document in
            let terms = BM25SpeciesCandidateRetriever.terms(document.combinedText)
            for term in Set(terms) { documentFrequency[term, default: 0] += 1 }
            return Entry(speciesID: document.speciesID,
                         termFrequencies: Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +),
                         length: terms.count,
                         normalizedNames: document.identityText.components(separatedBy: " | ").map(BM25SpeciesCandidateRetriever.normalizedPhrase))
        }
        averageLength = entries.isEmpty ? 1 : max(1, Double(entries.reduce(0) { $0 + $1.length }) / Double(entries.count))
        self.documentFrequency = documentFrequency
    }
}
