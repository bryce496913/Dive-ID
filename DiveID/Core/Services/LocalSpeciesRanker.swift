import Foundation

protocol SpeciesRanking: Sendable {
    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies]
}

struct RankedLocalSpecies: Sendable {
    let profile: LocalSpeciesProfile
    let score: Double
    let matchedClues: [String]
    let conflictingClues: [String]
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
    let informationLevel: ObservationInformationLevel
}

struct LocalRankingWeights: Sendable {
    let exactName = 20.0, category = 6.0, region = 5.0, habitat = 4.0, marking = 4.0, color = 3.0, bodyShape = 3.0, size = 3.0, depth = 2.0, behavior = 2.0, keyword = 1.0, waterConflict = -10.0, sizeConflict = -4.0, habitatConflict = -3.0
    let threshold = 4.0, maximumRawScore = 42.0
}

struct LocalSpeciesRanker: SpeciesRanking {
    let weights: LocalRankingWeights
    init(weights: LocalRankingWeights = LocalRankingWeights()) { self.weights = weights }

    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies] {
        let info = Self.informationLevel(observation)
        if info == .insufficient { return [] }
        var seen = Set<UUID>()
        let ranked = profiles.compactMap { profile -> RankedLocalSpecies? in
            guard seen.insert(profile.id).inserted else { return nil }
            var score = 0.0
            var matched: [String] = []
            var conflicts: [String] = []
            let nameTerms = ([profile.commonName, profile.scientificName] + profile.aliases).map { $0.lowercased() }
            if nameTerms.contains(where: { observation.normalizedText.contains($0) }) { score += weights.exactName; matched.append(profile.commonName) }
            add(observation.categories, profile.categories, weights.category, &score, &matched)
            add(observation.regions, profile.regions, weights.region, &score, &matched)
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
            if let size = observation.approximateSizeCentimeters, let min = profile.minimumSizeCentimeters, let max = profile.maximumSizeCentimeters {
                if (min * 0.5)...(max * 1.5) ~= size { score += weights.size; matched.append("compatible size") } else { score += weights.sizeConflict; conflicts.append("described size") }
            }
            if let depth = observation.approximateDepthMeters, let min = profile.minimumDepthMeters, let max = profile.maximumDepthMeters, (min - 3)...(max + 5) ~= depth { score += weights.depth; matched.append("compatible depth") }
            if observation.categories.contains("fish"), profile.categories.contains("turtle") || profile.categories.contains("ray") { score += weights.waterConflict; conflicts.append("animal group") }
            if !observation.habitats.isEmpty, observation.habitats.intersection(Set(profile.habitats)).isEmpty, score > 0 { score += weights.habitatConflict; conflicts.append("habitat") }
            score += occurrenceWeight(profile.regionalOccurrence)
            guard score >= weights.threshold else { return nil }
            var normalized = max(0, min(1, score / weights.maximumRawScore))
            if info == .limited { normalized = min(normalized, 0.64) }
            return RankedLocalSpecies(profile: profile, score: normalized, matchedClues: unique(matched), conflictingClues: unique(conflicts), matchedAppearanceVariant: bestVariant, informationLevel: info)
        }
        return Array(ranked.sorted { a, b in a.score == b.score ? a.profile.commonName < b.profile.commonName : a.score > b.score }.prefix(10))
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
}
