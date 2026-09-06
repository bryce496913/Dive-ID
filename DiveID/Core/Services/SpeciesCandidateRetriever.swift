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

/// A small, dependency-free BM25 retriever. It deliberately indexes the complete
/// canonical document rather than recreating the structured vocabulary as aliases.
struct BM25SpeciesCandidateRetriever: SpeciesCandidateRetrieving {
    let saturation: Double
    let lengthNormalization: Double

    init(saturation: Double = 1.2, lengthNormalization: Double = 0.75) {
        self.saturation = saturation
        self.lengthNormalization = lengthNormalization
    }

    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        guard limit > 0, !documents.isEmpty else { return [] }
        let queryTerms = Self.terms(query).filter { !Self.stopWords.contains($0) }
        guard !queryTerms.isEmpty else { return [] }
        let uniqueQueryTerms = Array(Set(queryTerms)).sorted()
        let indexed = documents.map { document in (document, Self.terms(document.combinedText)) }
        let averageLength = max(1, Double(indexed.reduce(0) { $0 + $1.1.count }) / Double(indexed.count))

        var documentFrequency: [String: Int] = [:]
        for (_, terms) in indexed {
            for term in Set(terms) where uniqueQueryTerms.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }

        let normalizedQuery = Self.normalizedPhrase(query)
        let count = Double(indexed.count)
        return indexed.compactMap { document, terms -> RetrievedSpeciesCandidate? in
            let frequencies = Dictionary(terms.map { ($0, 1) }, uniquingKeysWith: +)
            var score = 0.0
            var matches: [String] = []
            for term in uniqueQueryTerms {
                guard let frequency = frequencies[term], frequency > 0 else { continue }
                let df = Double(documentFrequency[term, default: 0])
                let inverseFrequency = log(1 + (count - df + 0.5) / (df + 0.5))
                let tf = Double(frequency)
                let denominator = tf + saturation * (1 - lengthNormalization + lengthNormalization * Double(terms.count) / averageLength)
                score += inverseFrequency * (tf * (saturation + 1)) / denominator
                matches.append(term)
            }

            let names = document.identityText.components(separatedBy: " | ").map(Self.normalizedPhrase)
            let exactName = names.contains(normalizedQuery)
            if exactName { score += 100 }
            guard score > 0 else { return nil }
            return RetrievedSpeciesCandidate(
                speciesID: document.speciesID,
                retrievalScore: score,
                evidence: exactName ? .exactName : .fullText,
                matchedTerms: matches
            )
        }.sorted { left, right in
            if left.retrievalScore != right.retrievalScore { return left.retrievalScore > right.retrievalScore }
            return left.speciesID.uuidString < right.speciesID.uuidString
        }.prefix(limit).map { $0 }
    }

    private static func terms(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map {
            LocalObservationParser.singular(String($0))
        }.filter { !$0.isEmpty }
    }

    private static func normalizedPhrase(_ text: String) -> String { terms(text).joined(separator: " ") }

    private static let stopWords: Set<String> = [
        "a", "an", "and", "animal", "at", "by", "in", "is", "it", "near", "of", "on", "the", "to", "with"
    ]
}
