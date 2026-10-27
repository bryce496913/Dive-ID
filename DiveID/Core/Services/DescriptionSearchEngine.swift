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
    let indexStore: SearchIndexStore
    private let regionResolver = RegionCompatibilityResolver()

    init(
        retriever: any SpeciesCandidateRetrieving = BM25SpeciesCandidateRetriever(),
        documentBuilder: any SpeciesSearchDocumentBuilding = SpeciesSearchDocumentBuilder(),
        parser: any ObservationParsing = LocalObservationParser(),
        ranker: any SpeciesRanking = LocalSpeciesRanker(),
        candidateLimit: Int = 50,
        indexStore: SearchIndexStore = .shared
    ) {
        self.retriever = retriever
        self.documentBuilder = documentBuilder
        self.parser = parser
        self.ranker = ranker
        self.candidateLimit = candidateLimit
        self.indexStore = indexStore
    }

    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        try await searchWithObservation(description: description, pack: pack).result
    }

    /// The search plus the parsed observation, which the semantic fallback needs to tell an
    /// empty result from a described subject the catalogue cannot contain.
    func searchWithObservation(description: String, pack: OfflineIdentificationPack) async throws
        -> (result: DescriptionSearchResult, observation: ParsedObservation) {
        try Task.checkCancellation()
        let observation = await parser.parse(description)
        try Task.checkCancellation()
        let retrieved = try await primaryCandidates(description: Self.retrievalQuery(description, observation), pack: pack)
        try Task.checkCancellation()
        let result = try await rank(description: description, observation: observation, retrieved: retrieved,
                                    pack: pack, retrievalLimit: candidateLimit)
        return (result, observation)
    }

    /// Ranks retrieved candidates in their retrieval order with the structured ranker.
    func rank(description: String, observation: ParsedObservation, retrieved: [RetrievedSpeciesCandidate],
              pack: OfflineIdentificationPack, retrievalLimit: Int) async throws -> DescriptionSearchResult {
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
            retrievalLimit: retrievalLimit
        )
    }

    /// The description plus the catalogue terms the parser recognised in it that it does not
    /// already contain, so retrieval matches "beaked" to beak and "toothy" to teeth as the
    /// ranker does. Recognised terms are added once each; the description is unchanged.
    static func retrievalQuery(_ description: String, _ observation: ParsedObservation) -> String {
        let canonical = observation.colors.union(observation.markings).union(observation.bodyShapes)
            .union(observation.habitats).union(observation.categories).union(observation.behaviors)
        // Compared in the singular, so "spine" in the text does not add "spines" a second time.
        let present = Set(LocalObservationParser.normalize(description).split { !$0.isLetter && !$0.isNumber }
            .map { LocalObservationParser.singular(String($0)) })
        let added = canonical.filter { term in
            !term.split(separator: " ").allSatisfy { present.contains(LocalObservationParser.singular(String($0))) }
        }.sorted()
        return added.isEmpty ? description : description + " " + added.joined(separator: " ")
    }

    func documents(pack: OfflineIdentificationPack) async throws -> [SpeciesSearchDocument] {
        try await indexStore.documents(pack: pack, builder: documentBuilder)
    }

    func contentKey(pack: OfflineIdentificationPack) -> String {
        SearchIndexStore.contentKey(pack, documentBuilder)
    }

    private func primaryCandidates(description: String, pack: OfflineIdentificationPack) async throws -> [RetrievedSpeciesCandidate] {
        if let bm25 = retriever as? BM25SpeciesCandidateRetriever {
            // The production path: the BM25 index is built once per catalogue content.
            let index = try await indexStore.index(pack: pack, builder: documentBuilder)
            return try await bm25.retrieve(query: description, index: index, limit: candidateLimit)
        }
        let documents = try await indexStore.documents(pack: pack, builder: documentBuilder)
        return try await retriever.retrieve(query: description, documents: documents, limit: candidateLimit)
    }
}

/// Production BM25, or (Debug, experimental) BM25 with a semantic fallback. The fallback
/// runs only when BM25 ranks nothing; see Docs/HybridRankingContract.md#semantic-calibration.
struct ConfiguredDescriptionSearchEngine: DescriptionSearching {
    let selection: DescriptionRetrievalEngine
    let bundle: Bundle
    let runtime: SemanticRetrievalRuntime
    let diagnostics: (any SemanticDiagnosticsReporting)?
    let weights: LocalRankingWeights
    /// Where a pack's semantic artifacts are; the app bundle unless a test supplies them.
    let locateArtifacts: (@Sendable (OfflineIdentificationPackID) throws -> SemanticArtifactLocations)?

    /// Fallback results shown at most; the pool is cut by cosine before ranking.
    static let fallbackResultLimit = 10

    init(selection: DescriptionRetrievalEngine = .productionDefault, bundle: Bundle = .main,
         runtime: SemanticRetrievalRuntime = SemanticRetrievalRuntime(), diagnostics: (any SemanticDiagnosticsReporting)? = nil,
         weights: LocalRankingWeights = LocalRankingWeights(),
         locateArtifacts: (@Sendable (OfflineIdentificationPackID) throws -> SemanticArtifactLocations)? = nil) {
        self.selection = selection; self.bundle = bundle; self.runtime = runtime; self.diagnostics = diagnostics
        self.weights = weights; self.locateArtifacts = locateArtifacts
    }

    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        let bm25Engine = HybridDescriptionSearchEngine(ranker: LocalSpeciesRanker(weights: weights))
        guard selection == .experimentalCoreML else { return try await bm25Engine.search(description: description, pack: pack) }
        let start = ContinuousClock.now
        let (bm25, observation) = try await bm25Engine.searchWithObservation(description: description, pack: pack)
        let packIdentity = "\(pack.metadata.id.rawValue):\(pack.metadata.packVersion)"
        func recordBM25(_ outcome: SemanticFallbackOutcome, reason: SemanticArtifactDiagnostic? = nil) async {
            let elapsed = Self.milliseconds(since: start)
            await diagnostics?.record(.init(requestedEngine: .experimentalCoreML, actualEngine: .productionBM25,
                modelIdentity: nil, tokenizerIdentity: nil, preprocessingIdentity: nil, packIdentity: packIdentity,
                fallbackReason: reason, modelCacheHit: false, indexCacheHit: false, queryCacheHit: false,
                loadMilliseconds: 0, embeddingMilliseconds: 0, retrievalMilliseconds: elapsed, totalMilliseconds: elapsed,
                fallbackOutcome: outcome))
        }
        // BM25 ranked something: return it unchanged, without loading the model or embedding.
        guard bm25.candidates.isEmpty else { await recordBM25(.notNeeded); return bm25 }
        // A described subject the catalogue cannot contain (a frog, a bird) stays unanswered.
        guard observation.domainContradiction == nil else { await recordBM25(.notAttempted); return bm25 }
        let locations: SemanticArtifactLocations
        do { locations = try locateArtifacts?(pack.metadata.id) ?? .bundled(packID: pack.metadata.id, bundle: bundle) }
        catch {
            try Task.checkCancellation()
            await recordBM25(.unavailable, reason: error as? SemanticArtifactDiagnostic ?? .malformedContract)
            return bm25
        }
        // The retriever records its own metrics (or a contained failure) here; the outcome is
        // added before they are passed on.
        let capture = SemanticDiagnosticsStore()
        let semantic = ExperimentalSemanticRetriever(pack: pack.metadata, locations: locations, runtime: runtime,
                                                     fallback: NoCandidateRetriever(), diagnostics: capture)
        let similar = try await semantic.retrieve(query: description, documents: try await bm25Engine.documents(pack: pack),
                                                  contentKey: bm25Engine.contentKey(pack: pack), limit: bm25Engine.candidateLimit)
        guard var metric = await capture.latest else { await recordBM25(.unavailable, reason: .semanticRuntimeFailure); return bm25 }
        // Frozen cutoff above every development no-match description's best cosine.
        let admitted = Array(similar.filter { $0.retrievalScore >= weights.semanticFallbackCosine }
            .prefix(Self.fallbackResultLimit))
        let fallback = admitted.isEmpty ? bm25 : try await bm25Engine.rank(
            description: description, observation: observation, retrieved: admitted, pack: pack, retrievalLimit: admitted.count)
        if metric.fallbackReason != nil {
            metric.fallbackOutcome = .unavailable
        } else if fallback.candidates.isEmpty {
            metric.actualEngine = .productionBM25
            metric.fallbackOutcome = .nothingAboveCutoff
        } else {
            metric.fallbackOutcome = .served
        }
        metric.totalMilliseconds = Self.milliseconds(since: start)
        await diagnostics?.record(metric)
        guard metric.fallbackOutcome == .served else { return bm25 }
        return Self.similarityOnly(fallback)
    }

    /// Fallback candidates are ordered by cosine, the only signal that admitted them (the
    /// ranker still applies its conflicts), and are always limited-information results.
    static func similarityOnly(_ result: DescriptionSearchResult) -> DescriptionSearchResult {
        let candidates = result.candidates.sorted {
            if ($0.retrievalRelevance ?? 0) != ($1.retrievalRelevance ?? 0) { return ($0.retrievalRelevance ?? 0) > ($1.retrievalRelevance ?? 0) }
            return $0.profile.id.uuidString < $1.profile.id.uuidString
        }.map {
            DescriptionSearchCandidate(profile: $0.profile, rawScore: $0.rawScore, retrievalRelevance: $0.retrievalRelevance,
                                       orderingScore: $0.orderingScore, score: min($0.score, LocalRankingWeights.limitedConfidenceCap),
                                       matchedEvidence: $0.matchedEvidence.contains(LocalRankingWeights.similarityClue)
                                           ? $0.matchedEvidence : $0.matchedEvidence + [LocalRankingWeights.similarityClue],
                                       conflictingEvidence: $0.conflictingEvidence, informationLevel: .limited,
                                       matchedAppearanceVariant: $0.matchedAppearanceVariant)
        }
        return DescriptionSearchResult(candidates: candidates, queryAnalysis: result.queryAnalysis,
                                       retrievedSpeciesIDs: result.retrievedSpeciesIDs, retrievalLimit: result.retrievalLimit)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
}

/// Contributes no candidates. The semantic fallback's own fallback: if the model fails,
/// the search keeps the BM25 result rather than running BM25 a second time.
struct NoCandidateRetriever: SpeciesCandidateRetrieving {
    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] { [] }
}
