import Foundation

protocol SpeciesRanking: Sendable {
    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies]
}

struct RankedLocalSpecies: Sendable {
    let profile: LocalSpeciesProfile
    let score: Double
    let matchedClues: [String]
    let conflictingClues: [String]
}

struct LocalRankingWeights: Sendable {
    let exactName = 20.0, category = 6.0, region = 5.0, habitat = 4.0, marking = 4.0, color = 3.0, bodyShape = 3.0, size = 3.0, depth = 2.0, behavior = 2.0, keyword = 1.0, waterConflict = -10.0, sizeConflict = -4.0, habitatConflict = -3.0
    let threshold = 4.0, maximumRawScore = 40.0
}

struct LocalSpeciesRanker: SpeciesRanking {
    let weights: LocalRankingWeights
    init(weights: LocalRankingWeights = LocalRankingWeights()) { self.weights = weights }

    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies] {
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
            add(observation.bodyShapes, profile.bodyShapes, weights.bodyShape, &score, &matched)
            add(observation.behaviors, profile.behaviors, weights.behavior, &score, &matched)
            add(observation.tokens, profile.keywords, weights.keyword, &score, &matched)
            if let size = observation.approximateSizeCentimeters, let min = profile.minimumSizeCentimeters, let max = profile.maximumSizeCentimeters {
                if (min * 0.5)...(max * 1.5) ~= size { score += weights.size; matched.append("compatible size") } else { score += weights.sizeConflict; conflicts.append("described size") }
            }
            if let depth = observation.approximateDepthMeters, let min = profile.minimumDepthMeters, let max = profile.maximumDepthMeters, (min - 3)...(max + 5) ~= depth { score += weights.depth; matched.append("compatible depth") }
            if observation.categories.contains("fish"), profile.categories.contains("turtle") || profile.categories.contains("ray") { score += weights.waterConflict; conflicts.append("animal group") }
            if !observation.habitats.isEmpty, observation.habitats.intersection(Set(profile.habitats)).isEmpty, score > 0 { score += weights.habitatConflict; conflicts.append("habitat") }
            guard score >= weights.threshold else { return nil }
            return RankedLocalSpecies(profile: profile, score: max(0, min(1, score / weights.maximumRawScore)), matchedClues: unique(matched), conflictingClues: unique(conflicts))
        }
        return Array(ranked.sorted { a, b in a.score == b.score ? a.profile.commonName < b.profile.commonName : a.score > b.score }.prefix(10))
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
