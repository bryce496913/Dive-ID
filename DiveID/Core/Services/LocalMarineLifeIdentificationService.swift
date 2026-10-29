import Foundation

enum LocalIdentificationError: Error, Equatable, Sendable {
    case invalidDescription
    case catalogUnavailable
    case catalogueLoadFailed(CatalogueLoadFailure)
    case unsupportedSource
    /// Photo identification is on, but no recognizer is available for the searched pack.
    case photoRecognizerUnavailable
    case regionMismatch(selected: OfflineIdentificationPackID, mentionedRegion: String)
}

struct LocalMarineLifeIdentificationService: MarineLifeIdentificationService {
    let catalogRepository: any MarineSpeciesCatalogRepository
    let searchEngine: any DescriptionSearching
    let diagnosticsReporter: any CatalogueDiagnosticsReporting
    /// Nil, or ignored, unless `features` enables photo identification (never in Release).
    let photoIdentification: PhotoIdentificationService?
    let features: FeatureAvailability

    init(catalogRepository: any MarineSpeciesCatalogRepository, searchEngine: any DescriptionSearching = HybridDescriptionSearchEngine(), diagnosticsReporter: any CatalogueDiagnosticsReporting = LocalCatalogueDiagnosticsReporter.shared,
         photoIdentification: PhotoIdentificationService? = nil, features: FeatureAvailability = .current) {
        self.catalogRepository = catalogRepository
        self.searchEngine = searchEngine
        self.diagnosticsReporter = diagnosticsReporter
        self.photoIdentification = photoIdentification
        self.features = features
    }

    init(catalogRepository: any MarineSpeciesCatalogRepository, parser: any ObservationParsing, ranker: any SpeciesRanking) {
        self.init(catalogRepository: catalogRepository, searchEngine: HybridDescriptionSearchEngine(parser: parser, ranker: ranker))
    }

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        try Task.checkCancellation()
        switch request.source {
        case .processedPhoto: return try await identifyOutcome(request: request, processedPhoto: processedPhoto).matches
        case .description(let description):
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { throw LocalIdentificationError.invalidDescription }
            let packID = request.context.region ?? DefaultDiveRegion.forNewInstalls
            let pack = try await loadPack(packID)
            try Task.checkCancellation()
            let result = try await searchEngine.search(description: trimmed, pack: pack)
            try Task.checkCancellation()
            if result.queryAnalysis.packRegionCompatibility == .conflicting,
               let outside = result.queryAnalysis.observedRegions.sorted().first {
                throw LocalIdentificationError.regionMismatch(selected: packID, mentionedRegion: outside.capitalized)
            }
            return result.candidates.prefix(10).enumerated().map { index, ranked in
                var match = Self.match(for: ranked, pack: pack, observationDescription: trimmed)
                match.rank = index + 1
                return match
            }
        }
    }

    func identifyOutcome(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> IdentificationOutcome {
        guard case .processedPhoto = request.source else {
            return IdentificationOutcome(matches: try await identify(request: request, processedPhoto: processedPhoto))
        }
        try Task.checkCancellation()
        // Release never gets here: the service is nil there, and the flag is checked as well.
        guard features.photoIdentificationEnabled, let photoIdentification else { throw LocalIdentificationError.unsupportedSource }
        guard let processedPhoto else { throw IdentificationSessionStoreError.photoNotFound }
        let pack = try await loadPack(request.context.region ?? DefaultDiveRegion.forNewInstalls)
        try Task.checkCancellation()
        return try await photoIdentification.identify(photo: processedPhoto, additionalDescription: request.context.additionalDescription, pack: pack)
    }

    /// A description search candidate as a displayed match (rank 1; the caller sets the rank).
    static func match(for ranked: DescriptionSearchCandidate, pack: OfflineIdentificationPack, observationDescription: String) -> IdentificationMatch {
        var species = ranked.profile.species
        species.packContext = PackContext(packID: pack.metadata.id, displayName: pack.metadata.displayName, packVersion: pack.metadata.packVersion)
        var match = IdentificationMatch(id: ranked.profile.id, species: species, score: ranked.score, scoreKind: .relativeMatch, strength: MatchStrength.band(for: ranked.score), explanation: explanation(matched: ranked.matchedEvidence, conflicts: ranked.conflictingEvidence, variant: ranked.matchedAppearanceVariant), distinguishingFeatures: ranked.profile.distinguishingFeatures, cautions: ranked.profile.cautions, taxonomicResolution: .species, observationDescription: observationDescription)
        match.packContext = species.packContext; match.matchedLifeStage = ranked.matchedAppearanceVariant?.lifeStage; match.informationLevel = ranked.informationLevel
        return match
    }

    /// The pack with the build's catalogue access, reporting load failures as a description search does.
    private func loadPack(_ packID: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        do {
            return try await catalogRepository.loadPack(id: packID)
        } catch is CancellationError {
            throw CancellationError()
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
    }

    private static func diagnosticCode(for error: LocalCatalogError) -> CatalogueDiagnosticCode {
        switch error {
        case .unsupportedPack, .unsupportedSchemaVersion: .unsupportedPack
        case .countMismatch: .countMismatch
        case .unknownControlledVocabularyValue: .vocabularyInvalid
        case .missingImage: .artworkMissing
        case .invalidImage, .imageTooLarge, .emptyImageAttribution, .unsupportedImageLicense, .duplicateImageFilename: .artworkInvalid
        case .publicationUnavailable: .publicationUnavailable
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
