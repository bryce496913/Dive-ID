import Foundation

protocol SpeciesRanking: Sendable {
    func rank(input: SpeciesRankingInput) async throws -> [RankedLocalSpecies]
}

/// Complete input to ranking. A nil retrieval signal deliberately identifies the
/// independently testable structured baseline rather than an unknown score.
struct SpeciesRankingInput: Sendable {
    let description: String
    let observation: ParsedObservation
    let candidates: [SpeciesRankingCandidate]
}

struct SpeciesRankingCandidate: Sendable {
    let speciesID: UUID
    let profile: LocalSpeciesProfile
    let retrieval: SpeciesRetrievalSignal?
}

struct SpeciesRetrievalSignal: Sendable, Equatable {
    let source: RetrievedSpeciesCandidate.Evidence
    let scoreKind: RetrievalScoreKind
    let score: Double
    let rank: Int
    let evidence: [String]
}

extension SpeciesRanking {
    /// Compatibility entry point for the structured engine and its direct tests.
    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies] {
        try await rank(input: SpeciesRankingInput(
            description: observation.normalizedText,
            observation: observation,
            candidates: profiles.map { SpeciesRankingCandidate(speciesID: $0.id, profile: $0, retrieval: nil) }
        ))
    }
}

struct RankedLocalSpecies: Sendable {
    let profile: LocalSpeciesProfile
    let rawScore: Double
    let retrievalRelevance: Double?
    let orderingScore: Double
    let score: Double
    let matchedClues: [String]
    let conflictingClues: [String]
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
    let informationLevel: ObservationInformationLevel
}

extension RankedLocalSpecies {
    init(profile: LocalSpeciesProfile, score: Double, matchedClues: [String], conflictingClues: [String], matchedAppearanceVariant: SpeciesAppearanceVariant?, informationLevel: ObservationInformationLevel) {
        self.profile = profile
        self.rawScore = score
        self.retrievalRelevance = nil
        self.orderingScore = score
        self.score = score
        self.matchedClues = matchedClues
        self.conflictingClues = conflictingClues
        self.matchedAppearanceVariant = matchedAppearanceVariant
        self.informationLevel = informationLevel
    }

}

struct LocalRankingWeights: Sendable {
    let exactName = 20.0, category = 6.0, region = 5.0, habitat = 4.0, marking = 4.0, color = 3.0, bodyShape = 3.0, size = 3.0, depth = 2.0, behavior = 2.0, keyword = 1.0, waterConflict = -10.0, sizeConflict = -4.0, habitatConflict = -3.0, regionConflict = -12.0
    let tailShape = 2.0, headAndMouth = 2.0, finAndSpine = 2.0
    let threshold = 4.0, maximumRawScore = 42.0
}

private struct RawRankedCandidate {
    let profile: LocalSpeciesProfile
    let rawScore: Double
    let matchedClues: [String]
    let conflictingClues: [String]
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
    let informationLevel: ObservationInformationLevel
    let retrievalRelevance: Double?
    let orderingScore: Double
}

struct LocalSpeciesRanker: SpeciesRanking {
    let weights: LocalRankingWeights
    private let regionResolver = RegionCompatibilityResolver()
    init(weights: LocalRankingWeights = LocalRankingWeights()) { self.weights = weights }

    func rank(input: SpeciesRankingInput) async throws -> [RankedLocalSpecies] {
        let observation = input.observation
        let observationInformation = Self.informationLevel(observation)
        let meaningfulTermCount = Self.meaningfulTerms(input.description).count
        var seen = Set<UUID>()
        let rawCandidates = input.candidates.compactMap { candidate -> RawRankedCandidate? in
            let profile = candidate.profile
            guard candidate.speciesID == profile.id, seen.insert(candidate.speciesID).inserted else { return nil }
            var score = 0.0
            var matched: [String] = []
            var conflicts: [String] = []
            let nameTerms = ([profile.commonName, profile.scientificName] + profile.aliases).map(LocalObservationParser.normalize)
            let hasExactName = nameTerms.contains {
                LocalObservationParser.matches($0, inTokens: observation.tokens, normalizedText: observation.normalizedText)
            }
            let retrievalRelevance = candidate.retrieval.map(Self.normalizedRelevance)
            let provisionalSemantic = candidate.retrieval?.scoreKind == .cosineSimilarity
                && (retrievalRelevance ?? 0) >= 0.65 && meaningfulTermCount >= 3
            guard observationInformation != .insufficient || hasExactName || provisionalSemantic else { return nil }
            let informationLevel: ObservationInformationLevel = hasExactName ? .sufficient
                : (provisionalSemantic && observationInformation == .insufficient ? .limited : observationInformation)
            if hasExactName { score += weights.exactName; matched.append(profile.commonName) }
            add(observation.categories, profile.categories, weights.category, &score, &matched)
            switch regionCompatibility(observedRegions: observation.regions, supportedRegions: Set(profile.regions)) {
            case .compatible:
                score += weights.region
                matched.append("geographic range")
            case .conflicting:
                score += weights.regionConflict
                conflicts.append("geographic range")
            case .unspecified:
                break
            }
            add(observation.habitats, profile.habitats, weights.habitat, &score, &matched)
            add(observation.markings, profile.markings, weights.marking, &score, &matched)
            add(observation.colors, profile.colors, weights.color, &score, &matched)
            var bestVariant: SpeciesAppearanceVariant? = nil
            var bestVariantScore = 0.0
            for variant in profile.appearanceVariants {
                var variantScore = 0.0; var variantHits: [String] = []
                add(observation.colors, variant.colors, weights.color, &variantScore, &variantHits)
                add(observation.markings, variant.markings, weights.marking, &variantScore, &variantHits)
                add(observation.bodyShapes, variant.bodyShapes, weights.bodyShape, &variantScore, &variantHits)
                if variantScore > bestVariantScore { bestVariantScore = variantScore; bestVariant = variant }
            }
            if let bestVariant, bestVariantScore >= weights.color { score += min(bestVariantScore, 6); matched.append("\(bestVariant.lifeStage.rawValue) appearance") }
            add(observation.bodyShapes, profile.bodyShapes, weights.bodyShape, &score, &matched)
            add(observation.behaviors, profile.behaviors, weights.behavior, &score, &matched)
            add(observation.tokens, profile.keywords, weights.keyword, &score, &matched)
            addVisibleClue(profile.tailShape.map { [$0] } ?? [], label: "tail shape", weight: weights.tailShape, observation: observation, legacyTerms: profile.markings + profile.bodyShapes + profile.keywords, score: &score, matched: &matched)
            addVisibleClue(profile.mouthAndHeadShape, label: "head and mouth shape", weight: weights.headAndMouth, observation: observation, legacyTerms: profile.markings + profile.bodyShapes + profile.keywords, score: &score, matched: &matched)
            addVisibleClue(profile.finAndSpineClues, label: "fin and spine clues", weight: weights.finAndSpine, observation: observation, legacyTerms: profile.markings + profile.bodyShapes + profile.keywords, score: &score, matched: &matched)
            let canonicalMinimum = profile.measurements?.typicalObservedMinimumCentimeters ?? profile.minimumSizeCentimeters
            let canonicalMaximum = profile.measurements?.typicalObservedMaximumCentimeters ?? profile.measurements?.maximumRecordedCentimeters ?? profile.maximumSizeCentimeters
            if let size = observation.approximateSizeCentimeters, let min = canonicalMinimum, let max = canonicalMaximum {
                if (min * 0.5)...(max * 1.5) ~= size { score += weights.size; matched.append("compatible size") } else { score += weights.sizeConflict; conflicts.append("described size") }
            }
            if let depth = observation.approximateDepthMeters, let min = profile.minimumDepthMeters, let max = profile.maximumDepthMeters, (min - 3)...(max + 5) ~= depth { score += weights.depth; matched.append("compatible depth") }
            if observation.categories.contains("fish"), profile.categories.contains("turtle") || profile.categories.contains("ray") { score += weights.waterConflict; conflicts.append("animal group") }
            if !observation.habitats.isEmpty, observation.habitats.intersection(Set(profile.habitats)).isEmpty, score > 0 { score += weights.habitatConflict; conflicts.append("habitat") }
            // Retrieval is normalized by its declared scale: cosine maps [-1, 1]
            // to [0, 1], while BM25 uses a saturating transform s/(s+3). This
            // avoids adding incompatible raw values. Semantic retrieval can grant
            // provisional eligibility, but never upgrades confidence by itself.
            guard score >= weights.threshold || hasExactName || provisionalSemantic else { return nil }
            let relevanceContribution = (retrievalRelevance ?? 0) * 8
            let orderingScore = score + relevanceContribution + occurrenceWeight(profile.regionalOccurrence)
            guard orderingScore > 0 else { return nil }
            if candidate.retrieval?.source == .semantic { matched.append("catalogue description similarity") }
            return RawRankedCandidate(profile: profile, rawScore: score, matchedClues: unique(matched), conflictingClues: unique(conflicts), matchedAppearanceVariant: bestVariant, informationLevel: informationLevel, retrievalRelevance: retrievalRelevance, orderingScore: orderingScore)
        }
        return rawCandidates.sorted { a, b in
            if a.orderingScore != b.orderingScore { return a.orderingScore > b.orderingScore }
            if a.profile.commonName != b.profile.commonName { return a.profile.commonName < b.profile.commonName }
            return a.profile.id.uuidString < b.profile.id.uuidString
        }.prefix(10).map { candidate in
            // Confidence remains structured evidence, not retrieval probability.
            var normalized = max(0, min(1, candidate.rawScore / weights.maximumRawScore))
            if candidate.informationLevel == .limited { normalized = min(normalized, 0.64) }
            return RankedLocalSpecies(profile: candidate.profile, rawScore: candidate.rawScore, retrievalRelevance: candidate.retrievalRelevance, orderingScore: candidate.orderingScore, score: normalized, matchedClues: candidate.matchedClues, conflictingClues: candidate.conflictingClues, matchedAppearanceVariant: candidate.matchedAppearanceVariant, informationLevel: candidate.informationLevel)
        }
    }

    private static func normalizedRelevance(_ signal: SpeciesRetrievalSignal) -> Double {
        switch signal.scoreKind {
        case .cosineSimilarity: return max(0, min(1, (signal.score + 1) / 2))
        case .bm25: return signal.score > 0 ? min(1, signal.score / (signal.score + 3)) : 0
        }
    }

    private static func meaningfulTerms(_ description: String) -> Set<String> {
        let ignored: Set<String> = ["a", "an", "and", "animal", "fish", "in", "is", "it", "of", "on", "the", "to", "with"]
        return Set(description.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !ignored.contains($0) })
    }

    func regionCompatibility(observedRegions: Set<String>, supportedRegions: Set<String>) -> RegionCompatibility {
        regionResolver.compatibility(observedRegions: observedRegions, supportedRegions: supportedRegions)
    }

    private func occurrenceWeight(_ status: RegionalOccurrenceStatus) -> Double { switch status { case .common: 3; case .regular: 2; case .introduced: 1; case .occasional, .seasonal: 0; case .rare: -3 } }

    private static func informationLevel(_ observation: ParsedObservation) -> ObservationInformationLevel {
        // Each boolean is an independent semantic clue group. Expanded synonyms stay
        // inside their source group and therefore never increase the evidence count.
        let groups = [
            !observation.categories.isEmpty,
            !observation.colors.isEmpty,
            !observation.markings.isEmpty,
            !observation.bodyShapes.isEmpty,
            !observation.habitats.isEmpty,
            !observation.behaviors.isEmpty,
            !observation.regions.isEmpty,
            observation.approximateSizeCentimeters != nil,
            observation.approximateDepthMeters != nil
        ]
        let count = groups.filter { $0 }.count
        if count >= 3 { return .sufficient }

        // Category, color, and approximate size are broad clues. Two of those alone
        // (for example, "dark fish" or "small fish") are still not identifying.
        let hasDistinctiveGroup = !observation.markings.isEmpty
            || !observation.bodyShapes.isEmpty
            || !observation.habitats.isEmpty
            || !observation.behaviors.isEmpty
            || !observation.regions.isEmpty
            || observation.approximateDepthMeters != nil
        if count >= 2, hasDistinctiveGroup { return .limited }
        return .insufficient
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func add(_ observed: Set<String>, _ profile: [String], _ weight: Double, _ score: inout Double, _ matched: inout [String]) {
        let hits = observed.intersection(Set(profile.map { $0.lowercased() })).sorted()
        score += Double(hits.count) * weight
        matched.append(contentsOf: hits)
    }

    private func addVisibleClue(_ clues: [String], label: String, weight: Double, observation: ParsedObservation, legacyTerms: [String], score: inout Double, matched: inout [String]) {
        let matchedLegacy = legacyTerms.map(LocalObservationParser.normalize).filter {
            LocalObservationParser.matches($0, inTokens: observation.tokens, normalizedText: observation.normalizedText)
        }
        let hasNewMatch = clues
            .map(LocalObservationParser.normalize)
            .filter { clue in
                let clueTokens = Set(clue.split(separator: " ").map(String.init).map(LocalObservationParser.singular))
                return !matchedLegacy.contains { legacy in
                    let legacyTokens = Set(legacy.split(separator: " ").map(String.init).map(LocalObservationParser.singular))
                    return !clueTokens.isDisjoint(with: legacyTokens)
                }
            }
            .contains { LocalObservationParser.matches($0, inTokens: observation.tokens, normalizedText: observation.normalizedText) }
        if hasNewMatch { score += weight; matched.append(label) }
    }
}
