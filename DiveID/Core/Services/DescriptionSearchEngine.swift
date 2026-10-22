import Foundation

/// A replaceable, domain-level description search boundary. Implementations return
/// catalogue candidates and evidence; application presentation remains the caller's job.
protocol DescriptionSearching: Sendable {
    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult
}

enum DescriptionSearchDisposition: String, Sendable, Equatable {
    /// Retrieval found no catalogue documents. This does not contain or retain query text.
    case noRetrievedCandidates
    /// Retrieval found documents, but the biological ranker rejected every candidate.
    case allCandidatesRejectedByRanker
    case rankedCandidates
}

struct DescriptionSearchDiagnostics: Sendable, Equatable {
    let disposition: DescriptionSearchDisposition
    let retrievedCandidateCount: Int
    let rankedCandidateCount: Int
}

struct DescriptionSearchResult: Sendable {
    let candidates: [DescriptionSearchCandidate]
    let queryAnalysis: DescriptionQueryAnalysis
    /// IDs admitted by retrieval before biological ranking. Structured search uses
    /// the complete pack, which makes candidate recall comparable across engines.
    let retrievedSpeciesIDs: [UUID]
    let retrievalLimit: Int
    var diagnostics: DescriptionSearchDiagnostics {
        .init(
            disposition: retrievedSpeciesIDs.isEmpty ? .noRetrievedCandidates : (candidates.isEmpty ? .allCandidatesRejectedByRanker : .rankedCandidates),
            retrievedCandidateCount: retrievedSpeciesIDs.count,
            rankedCandidateCount: candidates.count
        )
    }
}

struct DescriptionQueryAnalysis: Sendable {
    let observedRegions: Set<String>
    let packRegionCompatibility: RegionCompatibility
}

struct DescriptionSearchCandidate: Sendable {
    let profile: LocalSpeciesProfile
    let rawScore: Double
    /// Normalized retrieval relevance, when a retriever participated. This is
    /// not an identification probability.
    let retrievalRelevance: Double?
    let orderingScore: Double
    let score: Double
    let matchedEvidence: [String]
    let conflictingEvidence: [String]
    let informationLevel: ObservationInformationLevel
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
}

/// Adapter for the original structured parser/ranker pipeline. Keeping all score and
/// evidence decisions in `LocalSpeciesRanker` guarantees this seam changes no behavior.
struct StructuredDescriptionSearchEngine: DescriptionSearching {
    let parser: any ObservationParsing
    let ranker: any SpeciesRanking
    private let regionResolver = RegionCompatibilityResolver()

    init(parser: any ObservationParsing = LocalObservationParser(), ranker: any SpeciesRanking = LocalSpeciesRanker()) {
        self.parser = parser
        self.ranker = ranker
    }

    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        let observation = await parser.parse(description)
        let compatibility = regionResolver.compatibility(
            observedRegions: observation.regions,
            supportedRegions: Set(pack.metadata.regionAliases)
        )
        let ranked = try await ranker.rank(input: SpeciesRankingInput(
            description: description,
            observation: observation,
            candidates: pack.profiles.map { SpeciesRankingCandidate(speciesID: $0.id, profile: $0, retrieval: nil) },
            groupNames: pack.groupNames
        ))
        return DescriptionSearchResult(
            candidates: ranked.map {
                DescriptionSearchCandidate(
                    profile: $0.profile,
                    rawScore: $0.rawScore,
                    retrievalRelevance: $0.retrievalRelevance,
                    orderingScore: $0.orderingScore,
                    score: $0.score,
                    matchedEvidence: $0.matchedClues,
                    conflictingEvidence: $0.conflictingClues,
                    informationLevel: $0.informationLevel,
                    matchedAppearanceVariant: $0.matchedAppearanceVariant
                )
            },
            queryAnalysis: DescriptionQueryAnalysis(
                observedRegions: observation.regions,
                packRegionCompatibility: compatibility
            ),
            retrievedSpeciesIDs: pack.profiles.map(\.id),
            retrievalLimit: pack.profiles.count
        )
    }
}

/// Retrieves a bounded lexical pool, then delegates every biological score,
/// conflict, confidence cap, and explanation decision to the structured ranker.
struct HybridDescriptionSearchEngine: DescriptionSearching {
    let retriever: any SpeciesCandidateRetrieving
    let documentBuilder: any SpeciesSearchDocumentBuilding
    let parser: any ObservationParsing
    let ranker: any SpeciesRanking
    let candidateLimit: Int
    private let regionResolver = RegionCompatibilityResolver()

    init(
        retriever: any SpeciesCandidateRetrieving = BM25SpeciesCandidateRetriever(),
        documentBuilder: any SpeciesSearchDocumentBuilding = SpeciesSearchDocumentBuilder(),
        parser: any ObservationParsing = LocalObservationParser(),
        ranker: any SpeciesRanking = LocalSpeciesRanker(),
        candidateLimit: Int = 50
    ) {
        self.retriever = retriever
        self.documentBuilder = documentBuilder
        self.parser = parser
        self.ranker = ranker
        self.candidateLimit = candidateLimit
    }

    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        try Task.checkCancellation()
        let observation = await parser.parse(description)
        try Task.checkCancellation()
        let retrieved: [RetrievedSpeciesCandidate]
        if let bm25 = retriever as? BM25SpeciesCandidateRetriever {
            // The production path: the BM25 index is built once per catalogue content.
            let index = await SearchDocumentCache.shared.index(pack: pack, builder: documentBuilder)
            retrieved = try await bm25.retrieve(query: description, index: index, limit: candidateLimit)
        } else {
            let documents = await SearchDocumentCache.shared.documents(pack: pack, builder: documentBuilder)
            retrieved = try await retriever.retrieve(query: description, documents: documents, limit: candidateLimit)
        }
        try Task.checkCancellation()
        let profileByID = Dictionary(pack.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var included = Set<UUID>()
        let pool = retrieved.enumerated().compactMap { offset, item -> SpeciesRankingCandidate? in
            guard included.insert(item.speciesID).inserted, let profile = profileByID[item.speciesID] else { return nil }
            return SpeciesRankingCandidate(
                speciesID: item.speciesID,
                profile: profile,
                retrieval: SpeciesRetrievalSignal(
                    source: item.evidence,
                    scoreKind: item.scoreKind,
                    score: item.retrievalScore,
                    rank: offset + 1,
                    evidence: item.matchedTerms
                )
            )
        }
        let ranked = try await ranker.rank(input: SpeciesRankingInput(description: description, observation: observation, candidates: pool, groupNames: pack.groupNames))
        let compatibility = regionResolver.compatibility(
            observedRegions: observation.regions,
            supportedRegions: Set(pack.metadata.regionAliases)
        )
        return DescriptionSearchResult(
            candidates: ranked.map {
                DescriptionSearchCandidate(
                    profile: $0.profile,
                    rawScore: $0.rawScore,
                    retrievalRelevance: $0.retrievalRelevance,
                    orderingScore: $0.orderingScore,
                    score: $0.score,
                    matchedEvidence: $0.matchedClues,
                    conflictingEvidence: $0.conflictingClues,
                    informationLevel: $0.informationLevel,
                    matchedAppearanceVariant: $0.matchedAppearanceVariant
                )
            },
            queryAnalysis: DescriptionQueryAnalysis(
                observedRegions: observation.regions,
                packRegionCompatibility: compatibility
            ),
            retrievedSpeciesIDs: retrieved.map(\.speciesID),
            retrievalLimit: candidateLimit
        )
    }
}

/// Search documents and the BM25 index for each catalogue content, built once and
/// reused by every query. The key is the pack's identity and version plus the content
/// fingerprint computed when the pack was built, so edited or filtered catalogues
/// (for example the Release subset) get their own entry. A few entries are kept.
private actor SearchDocumentCache {
    static let shared = SearchDocumentCache()
    private struct Entry { let documents: [SpeciesSearchDocument]; var index: BM25Index? }
    private var values: [String: Entry] = [:]
    private var order: [String] = []
    private let capacity = 6

    private func key(_ pack: OfflineIdentificationPack, _ builder: any SpeciesSearchDocumentBuilding) -> String {
        "\(pack.metadata.id.rawValue):\(pack.metadata.packVersion):\(pack.profiles.count):\(pack.contentFingerprint):\(String(reflecting: type(of: builder)))"
    }

    private func entry(_ pack: OfflineIdentificationPack, _ builder: any SpeciesSearchDocumentBuilding) -> (String, Entry) {
        let key = key(pack, builder)
        if let cached = values[key] { return (key, cached) }
        let entry = Entry(documents: pack.profiles.map { builder.document(from: $0, pack: pack.metadata) }, index: nil)
        values[key] = entry
        order.append(key)
        if order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
        return (key, entry)
    }

    func documents(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> [SpeciesSearchDocument] {
        entry(pack, builder).1.documents
    }

    func index(pack: OfflineIdentificationPack, builder: any SpeciesSearchDocumentBuilding) -> BM25Index {
        var (key, entry) = entry(pack, builder)
        if let index = entry.index { return index }
        let index = BM25Index(documents: entry.documents)
        entry.index = index
        values[key] = entry
        return index
    }
}

struct ConfiguredDescriptionSearchEngine: DescriptionSearching {
    let selection: DescriptionRetrievalEngine
    let bundle: Bundle
    let runtime: SemanticRetrievalRuntime
    let diagnostics: (any SemanticDiagnosticsReporting)?

    init(selection: DescriptionRetrievalEngine = .productionDefault, bundle: Bundle = .main,
         runtime: SemanticRetrievalRuntime = SemanticRetrievalRuntime(), diagnostics: (any SemanticDiagnosticsReporting)? = nil) {
        self.selection = selection; self.bundle = bundle; self.runtime = runtime; self.diagnostics = diagnostics
    }

    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        guard selection == .experimentalCoreML else { return try await HybridDescriptionSearchEngine().search(description: description, pack: pack) }
        let locations: SemanticArtifactLocations
        do { locations = try .bundled(packID: pack.metadata.id, bundle: bundle) }
        catch {
            try Task.checkCancellation()
            let start = ContinuousClock.now
            let result = try await HybridDescriptionSearchEngine().search(description: description, pack: pack)
            let duration = start.duration(to: .now).components
            await diagnostics?.record(.init(requestedEngine: .experimentalCoreML, actualEngine: .productionBM25,
                modelIdentity: nil, tokenizerIdentity: nil, preprocessingIdentity: nil,
                packIdentity: "\(pack.metadata.id.rawValue):\(pack.metadata.packVersion)",
                fallbackReason: error as? SemanticArtifactDiagnostic ?? .malformedContract,
                modelCacheHit: false, indexCacheHit: false, queryCacheHit: false, loadMilliseconds: 0,
                embeddingMilliseconds: 0, retrievalMilliseconds: Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15,
                totalMilliseconds: Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15))
            return result
        }
        let retriever = ExperimentalSemanticRetriever(pack: pack.metadata, locations: locations, runtime: runtime,
                                                       fallback: BM25SpeciesCandidateRetriever(), diagnostics: diagnostics)
        return try await HybridDescriptionSearchEngine(retriever: retriever).search(description: description, pack: pack)
    }
}
