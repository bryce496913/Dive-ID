import Foundation

enum LocalIdentificationError: Error, Equatable, Sendable {
    case invalidDescription
    case catalogUnavailable
    case unsupportedSource
    case regionMismatch(selected: OfflineIdentificationPackID, mentionedRegion: String)
}

struct LocalMarineLifeIdentificationService: MarineLifeIdentificationService {
    let catalogRepository: any MarineSpeciesCatalogRepository
    let parser: any ObservationParsing
    let ranker: any SpeciesRanking
    private let regionResolver = RegionCompatibilityResolver()

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        switch request.source {
        case .processedPhoto: throw LocalIdentificationError.unsupportedSource
        case .description(let description):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 5 else { throw LocalIdentificationError.invalidDescription }
            let packID = request.context.region ?? .caribbean
            let pack: OfflineIdentificationPack
            do { pack = try await catalogRepository.loadPack(id: packID) } catch { throw LocalIdentificationError.catalogUnavailable }
            let observation = await parser.parse(trimmed)
            let supportedRegions = Set(pack.metadata.regionAliases)
            if regionCompatibility(observedRegions: observation.regions, supportedRegions: supportedRegions) == .conflicting,
               let outside = observation.regions.sorted().first {
                throw LocalIdentificationError.regionMismatch(selected: packID, mentionedRegion: outside.capitalized)
            }
            let ranked = try await ranker.rank(observation: observation, profiles: pack.profiles)
            return ranked.prefix(10).enumerated().map { index, ranked in
                var species = ranked.profile.species
                species.packContext = PackContext(packID: pack.metadata.id, displayName: pack.metadata.displayName, packVersion: pack.metadata.packVersion)
                var match = IdentificationMatch(id: ranked.profile.id, species: species, rank: index + 1, score: ranked.score, scoreKind: .relativeMatch, strength: MatchStrength.band(for: ranked.score), explanation: Self.explanation(matched: ranked.matchedClues, conflicts: ranked.conflictingClues, variant: ranked.matchedAppearanceVariant), distinguishingFeatures: ranked.profile.distinguishingFeatures, cautions: ranked.profile.cautions, taxonomicResolution: .species, observationDescription: trimmed)
                match.packContext = species.packContext; match.matchedLifeStage = ranked.matchedAppearanceVariant?.lifeStage; match.informationLevel = ranked.informationLevel
                return match
            }
        }
    }

    func regionCompatibility(observedRegions: Set<String>, supportedRegions: Set<String>) -> RegionCompatibility {
        regionResolver.compatibility(observedRegions: observedRegions, supportedRegions: supportedRegions)
    }

    static func explanation(matched: [String], conflicts: [String], variant: SpeciesAppearanceVariant? = nil) -> String {
        var clues = matched.prefix(5).joined(separator: ", ")
        if let variant { clues += clues.isEmpty ? variant.description : ", and \(variant.lifeStage.rawValue) appearance" }
        let prefix = clues.isEmpty ? "Matched clues in the selected offline pack" : "Matched " + clues
        if let conflict = conflicts.first { return prefix + ", but the " + conflict + " clue is less typical." }
        return prefix + " in the selected offline pack."
    }
}
