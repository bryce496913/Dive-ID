import Foundation

protocol SpeciesRanking: Sendable {
    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies]
}

struct RankedLocalSpecies: Sendable {
    let profile: LocalSpeciesProfile
    let rawScore: Double
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

enum RegionCompatibility: Equatable, Sendable { case unspecified, compatible, conflicting }

struct RegionCompatibilityResolver: Sendable {
    private let parents: [String: Set<String>] = [
        "caribbean": ["western atlantic", "atlantic"], "western atlantic": ["atlantic"], "florida": ["western atlantic", "atlantic"], "bahamas": ["caribbean", "western atlantic", "atlantic"], "bermuda": ["western atlantic", "atlantic"], "gulf of mexico": ["western atlantic", "atlantic"], "belize": ["caribbean", "western atlantic", "atlantic"], "cayman islands": ["caribbean", "western atlantic", "atlantic"], "cozumel": ["caribbean", "western atlantic", "atlantic"], "bonaire": ["caribbean", "western atlantic", "atlantic"], "curaçao": ["caribbean", "western atlantic", "atlantic"], "curacao": ["caribbean", "western atlantic", "atlantic"], "aruba": ["caribbean", "western atlantic", "atlantic"], "turks and caicos": ["caribbean", "western atlantic", "atlantic"], "puerto rico": ["caribbean", "western atlantic", "atlantic"], "us virgin islands": ["caribbean", "western atlantic", "atlantic"], "british virgin islands": ["caribbean", "western atlantic", "atlantic"], "dominican republic": ["caribbean", "western atlantic", "atlantic"], "jamaica": ["caribbean", "western atlantic", "atlantic"],
        "fiji": ["indo-pacific", "pacific"], "indo-pacific": ["pacific", "indian"], "hawaii": ["pacific"]
    ]

    func compatibility(observedRegions: Set<String>, profileRegions: Set<String>) -> RegionCompatibility {
        let observed = Set(observedRegions.map(Self.normalize)).filter { LocalObservationVocabulary.regions.contains($0) }
        let profile = Set(profileRegions.map(Self.normalize)).filter { LocalObservationVocabulary.regions.contains($0) }
        guard !observed.isEmpty, !profile.isEmpty else { return .unspecified }
        for observedRegion in observed {
            let observedFamily = family(for: observedRegion)
            for profileRegion in profile where !observedFamily.isDisjoint(with: family(for: profileRegion)) { return .compatible }
        }
        return .conflicting
    }

    private static func normalize(_ value: String) -> String { LocalObservationParser.normalize(value).replacingOccurrences(of: "indo pacific", with: "indo-pacific") }
    private func family(for region: String) -> Set<String> { Set([region]).union(parents[region] ?? []) }
}

private struct RawRankedCandidate {
    let profile: LocalSpeciesProfile
    let rawScore: Double
    let matchedClues: [String]
    let conflictingClues: [String]
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
    let informationLevel: ObservationInformationLevel
}

struct LocalSpeciesRanker: SpeciesRanking {
    let weights: LocalRankingWeights
    private let regionResolver = RegionCompatibilityResolver()
    init(weights: LocalRankingWeights = LocalRankingWeights()) { self.weights = weights }

    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies] {
        let info = Self.informationLevel(observation)
        if info == .insufficient { return [] }
        var seen = Set<UUID>()
        let rawCandidates = profiles.compactMap { profile -> RawRankedCandidate? in
            guard seen.insert(profile.id).inserted else { return nil }
            var score = 0.0
            var matched: [String] = []
            var conflicts: [String] = []
            let nameTerms = ([profile.commonName, profile.scientificName] + profile.aliases).map { $0.lowercased() }
            if nameTerms.contains(where: { observation.normalizedText.contains($0) }) { score += weights.exactName; matched.append(profile.commonName) }
            add(observation.categories, profile.categories, weights.category, &score, &matched)
            switch regionResolver.compatibility(observedRegions: observation.regions, profileRegions: Set(profile.regions)) {
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
            score += occurrenceWeight(profile.regionalOccurrence)
            guard score >= weights.threshold else { return nil }
            return RawRankedCandidate(profile: profile, rawScore: score, matchedClues: unique(matched), conflictingClues: unique(conflicts), matchedAppearanceVariant: bestVariant, informationLevel: info)
        }
        return rawCandidates.sorted { a, b in
            if a.rawScore != b.rawScore { return a.rawScore > b.rawScore }
            if a.profile.commonName != b.profile.commonName { return a.profile.commonName < b.profile.commonName }
            return a.profile.id.uuidString < b.profile.id.uuidString
        }.prefix(10).map { candidate in
            var normalized = max(0, min(1, candidate.rawScore / weights.maximumRawScore))
            if candidate.informationLevel == .limited { normalized = min(normalized, 0.64) }
            return RankedLocalSpecies(profile: candidate.profile, rawScore: candidate.rawScore, score: normalized, matchedClues: candidate.matchedClues, conflictingClues: candidate.conflictingClues, matchedAppearanceVariant: candidate.matchedAppearanceVariant, informationLevel: candidate.informationLevel)
        }
    }

    private func occurrenceWeight(_ status: RegionalOccurrenceStatus) -> Double { switch status { case .common: 3; case .regular: 2; case .introduced: 1; case .occasional, .seasonal: 0; case .rare: -3 } }

    private static func informationLevel(_ observation: ParsedObservation) -> ObservationInformationLevel {
        let count = [!observation.categories.isEmpty, !observation.colors.isEmpty, !observation.markings.isEmpty, !observation.bodyShapes.isEmpty, !observation.habitats.isEmpty, !observation.behaviors.isEmpty, !observation.regions.isEmpty, observation.approximateSizeCentimeters != nil, observation.approximateDepthMeters != nil].filter { $0 }.count
        if count >= 3 || observation.tokens.count >= 5 { return .sufficient }
        if count >= 2 || observation.tokens.count >= 3 { return .limited }
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
