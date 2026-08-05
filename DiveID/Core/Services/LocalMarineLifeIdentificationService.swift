import Foundation

enum LocalIdentificationError: Error, Equatable, Sendable {
    case invalidDescription
    case catalogUnavailable
    case unsupportedSource
}

struct LocalMarineLifeIdentificationService: MarineLifeIdentificationService {
    let catalogRepository: any MarineSpeciesCatalogRepository
    let parser: any ObservationParsing
    let ranker: any SpeciesRanking

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        switch request.source {
        case .processedPhoto:
            throw LocalIdentificationError.unsupportedSource
        case .description(let description):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 5 else { throw LocalIdentificationError.invalidDescription }
            try Task.checkCancellation()
            let profiles: [LocalSpeciesProfile]
            do { profiles = try await catalogRepository.loadProfiles() } catch { throw LocalIdentificationError.catalogUnavailable }
            try Task.checkCancellation()
            let observation = await parser.parse(trimmed)
            try Task.checkCancellation()
            let ranked = try await ranker.rank(observation: observation, profiles: profiles)
            try Task.checkCancellation()
            return ranked.enumerated().map { index, ranked in
                IdentificationMatch(
                    id: ranked.profile.id,
                    species: ranked.profile.species,
                    rank: index + 1,
                    score: ranked.score,
                    scoreKind: .relativeMatch,
                    strength: MatchStrength.band(for: ranked.score),
                    explanation: Self.explanation(matched: ranked.matchedClues, conflicts: ranked.conflictingClues),
                    distinguishingFeatures: ranked.profile.distinguishingFeatures,
                    cautions: ranked.profile.cautions,
                    taxonomicResolution: .species,
                    observationDescription: trimmed
                )
            }
        }
    }

    static func explanation(matched: [String], conflicts: [String]) -> String {
        let prefix = matched.isEmpty ? "Matched clues in the offline catalogue" : "Matched " + matched.prefix(5).joined(separator: ", ")
        if let conflict = conflicts.first { return prefix + ", but the " + conflict + " clue is less typical." }
        return prefix + " in the offline catalogue."
    }
}
