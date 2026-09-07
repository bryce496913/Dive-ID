import Foundation

enum LocalIdentificationError: Error, Equatable, Sendable {
    case invalidDescription
    case catalogUnavailable
    case catalogueLoadFailed(CatalogueLoadFailure)
    case unsupportedSource
    case regionMismatch(selected: OfflineIdentificationPackID, mentionedRegion: String)
}

struct LocalMarineLifeIdentificationService: MarineLifeIdentificationService {
    let catalogRepository: any MarineSpeciesCatalogRepository
    let searchEngine: any DescriptionSearching
    let diagnosticsReporter: any CatalogueDiagnosticsReporting

    init(catalogRepository: any MarineSpeciesCatalogRepository, searchEngine: any DescriptionSearching = HybridDescriptionSearchEngine(), diagnosticsReporter: any CatalogueDiagnosticsReporting = LocalCatalogueDiagnosticsReporter.shared) {
        self.catalogRepository = catalogRepository
        self.searchEngine = searchEngine
        self.diagnosticsReporter = diagnosticsReporter
    }

    init(catalogRepository: any MarineSpeciesCatalogRepository, parser: any ObservationParsing, ranker: any SpeciesRanking) {
        self.init(catalogRepository: catalogRepository, searchEngine: HybridDescriptionSearchEngine(parser: parser, ranker: ranker))
    }

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        switch request.source {
        case .processedPhoto: throw LocalIdentificationError.unsupportedSource
        case .description(let description):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 5 else { throw LocalIdentificationError.invalidDescription }
            let packID = request.context.region ?? .caribbean
            let pack: OfflineIdentificationPack
            do {
                pack = try await catalogRepository.loadPack(id: packID)
            } catch let failure as CatalogueLoadFailure {
                await diagnosticsReporter.record(failure)
                throw LocalIdentificationError.catalogueLoadFailed(failure)
            } catch let error as LocalCatalogError {
                let failure = CatalogueLoadFailure(packID: packID, code: Self.diagnosticCode(for: error), catalogError: error, resource: nil, phase: .validation)
                await diagnosticsReporter.record(failure)
                throw LocalIdentificationError.catalogueLoadFailed(failure)
            } catch {
                let failure = CatalogueLoadFailure(packID: packID, code: .validationFailed, catalogError: nil, resource: nil, phase: .validation)
                await diagnosticsReporter.record(failure)
                throw LocalIdentificationError.catalogueLoadFailed(failure)
            }
            let result = try await searchEngine.search(description: trimmed, pack: pack)
            if result.queryAnalysis.packRegionCompatibility == .conflicting,
               let outside = result.queryAnalysis.observedRegions.sorted().first {
                throw LocalIdentificationError.regionMismatch(selected: packID, mentionedRegion: outside.capitalized)
            }
            return result.candidates.prefix(10).enumerated().map { index, ranked in
                var species = ranked.profile.species
                species.packContext = PackContext(packID: pack.metadata.id, displayName: pack.metadata.displayName, packVersion: pack.metadata.packVersion)
                var match = IdentificationMatch(id: ranked.profile.id, species: species, rank: index + 1, score: ranked.score, scoreKind: .relativeMatch, strength: MatchStrength.band(for: ranked.score), explanation: Self.explanation(matched: ranked.matchedEvidence, conflicts: ranked.conflictingEvidence, variant: ranked.matchedAppearanceVariant), distinguishingFeatures: ranked.profile.distinguishingFeatures, cautions: ranked.profile.cautions, taxonomicResolution: .species, observationDescription: trimmed)
                match.packContext = species.packContext; match.matchedLifeStage = ranked.matchedAppearanceVariant?.lifeStage; match.informationLevel = ranked.informationLevel
                return match
            }
        }
    }

    private static func diagnosticCode(for error: LocalCatalogError) -> CatalogueDiagnosticCode {
        switch error {
        case .unsupportedPack, .unsupportedSchemaVersion: .unsupportedPack
        case .countMismatch: .countMismatch
        case .unknownControlledVocabularyValue: .vocabularyInvalid
        case .missingImage: .artworkMissing
        case .invalidImage, .imageTooLarge, .emptyImageAttribution, .unsupportedImageLicense, .duplicateImageFilename: .artworkInvalid
        default: .validationFailed
        }
    }

    static func explanation(matched: [String], conflicts: [String], variant: SpeciesAppearanceVariant? = nil) -> String {
        var clues = matched.prefix(5).joined(separator: ", ")
        if let variant { clues += clues.isEmpty ? variant.description : ", and \(variant.lifeStage.rawValue) appearance" }
        let prefix = clues.isEmpty ? "Matched clues in the selected offline pack" : "Matched " + clues
        if let conflict = conflicts.first { return prefix + ", but the " + conflict + " clue is less typical." }
        return prefix + " in the selected offline pack."
    }
}
