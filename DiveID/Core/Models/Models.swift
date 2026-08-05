import Foundation

struct Species: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let commonName: String
    let scientificName: String
    let summary: String
    let visualCharacteristics: [String]
    let habitat: String
    let geographicRange: String
    let imageAssetName: String?
    var bundledImage: BundledSpeciesImage? = nil
    var packContext: PackContext? = nil
    var regionalOccurrence: String? = nil
    var appearanceVariants: [SpeciesAppearanceVariant] = []
    var similarSpecies: [SimilarSpeciesComparison] = []
}

enum MatchScoreKind: String, Codable, Sendable {
    case relativeMatch
    case calibratedProbability
}

enum MatchStrength: String, Codable, CaseIterable, Sendable {
    case strong, good, possible, weak

    var displayName: String { rawValue.capitalized + " match" }

    static func band(for score: Double) -> Self {
        switch score {
        case 0.85...: .strong
        case 0.65..<0.85: .good
        case 0.40..<0.65: .possible
        default: .weak
        }
    }
}

enum TaxonomicResolution: String, Codable, Sendable { case species, genus, family, group }

struct IdentificationMatch: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let species: Species
    var rank: Int = 1
    let score: Double
    let scoreKind: MatchScoreKind
    var strength: MatchStrength? = nil
    var explanation: String = ""
    var distinguishingFeatures: [String] = []
    var cautions: [String] = []
    var taxonomicResolution: TaxonomicResolution = .species
    var observationDescription: String = ""
    var sourceSessionID: UUID? = nil
    var packContext: PackContext? = nil
    var matchedLifeStage: SpeciesLifeStage? = nil
    var informationLevel: ObservationInformationLevel? = nil

    var matchStrength: MatchStrength { strength ?? .band(for: score) }
}

struct SavedIdentification: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let species: Species
    let matchRank: Int
    let matchStrength: MatchStrength
    let relativeScore: Double?
    let explanation: String
    let distinguishingFeatures: [String]
    let cautions: [String]
    let taxonomicResolution: TaxonomicResolution
    let observationDescription: String
    let identifiedAt: Date
    var diveNotes: String?
    let sourceSessionID: UUID?
    let packContext: PackContext?
    let matchedLifeStage: SpeciesLifeStage?

    init(id: UUID = UUID(), match: IdentificationMatch, identifiedAt: Date = Date(), diveNotes: String? = nil) {
        self.id = id; species = match.species; matchRank = match.rank; matchStrength = match.matchStrength
        relativeScore = match.scoreKind == .relativeMatch ? match.score : nil; explanation = match.explanation
        distinguishingFeatures = match.distinguishingFeatures; cautions = match.cautions
        taxonomicResolution = match.taxonomicResolution; observationDescription = match.observationDescription
        self.identifiedAt = identifiedAt; self.diveNotes = diveNotes; sourceSessionID = match.sourceSessionID; packContext = match.packContext; matchedLifeStage = match.matchedLifeStage
    }

    var match: IdentificationMatch {
        var value = IdentificationMatch(id: species.id, species: species, rank: matchRank, score: relativeScore ?? 0, scoreKind: .relativeMatch, strength: matchStrength, explanation: explanation, distinguishingFeatures: distinguishingFeatures, cautions: cautions, taxonomicResolution: taxonomicResolution)
        value.observationDescription = observationDescription; value.sourceSessionID = sourceSessionID; value.packContext = packContext; value.matchedLifeStage = matchedLifeStage; return value
    }
}

enum WaterType: String, Codable, CaseIterable, Sendable {
    case saltwater, freshwater, brackish, unknown
}

struct IdentificationContext: Hashable, Codable, Sendable {
    var region: OfflineIdentificationPackID?
    var waterType: WaterType?
    var approximateDepthMeters: Double?
    var habitat: String?
    var approximateSize: String?
    var behavior: String?
    var observedAt: Date?

    static let empty = IdentificationContext()
}

struct ProcessedPhotoReference: Hashable, Codable, Sendable {
    let id: UUID
}

enum ProcessedPhotoFormat: String, Codable, Sendable { case jpeg }

struct ProcessedPhoto: Hashable, Sendable {
    let id: UUID
    let previewData: Data
    let uploadData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let format: ProcessedPhotoFormat

    var reference: ProcessedPhotoReference { .init(id: id) }
}

enum IdentificationSource: Hashable, Sendable {
    case description(String)
    case processedPhoto(ProcessedPhotoReference)
}

struct IdentificationRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let source: IdentificationSource
    let context: IdentificationContext
    let createdAt: Date

    init(id: UUID = UUID(), source: IdentificationSource, context: IdentificationContext = .empty, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.context = context
        self.createdAt = createdAt
    }
}

struct IdentificationSessionResult: Sendable {
    let matches: [IdentificationMatch]
    let completedAt: Date
}

enum LoadState<Value> {
    case idle, loading, loaded(Value), empty, failed(String, retryable: Bool)
}

extension SavedIdentification {
    enum CodingKeys: String, CodingKey { case id, species, matchRank, matchStrength, relativeScore, explanation, distinguishingFeatures, cautions, taxonomicResolution, observationDescription, identifiedAt, diveNotes, sourceSessionID, packContext, matchedLifeStage }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); species = try c.decode(Species.self, forKey: .species); matchRank = try c.decode(Int.self, forKey: .matchRank); matchStrength = try c.decode(MatchStrength.self, forKey: .matchStrength); relativeScore = try c.decodeIfPresent(Double.self, forKey: .relativeScore); explanation = try c.decode(String.self, forKey: .explanation); distinguishingFeatures = try c.decodeIfPresent([String].self, forKey: .distinguishingFeatures) ?? []; cautions = try c.decodeIfPresent([String].self, forKey: .cautions) ?? []; taxonomicResolution = try c.decodeIfPresent(TaxonomicResolution.self, forKey: .taxonomicResolution) ?? .species; observationDescription = try c.decodeIfPresent(String.self, forKey: .observationDescription) ?? ""; identifiedAt = try c.decode(Date.self, forKey: .identifiedAt); diveNotes = try c.decodeIfPresent(String.self, forKey: .diveNotes); sourceSessionID = try c.decodeIfPresent(UUID.self, forKey: .sourceSessionID); packContext = try c.decodeIfPresent(PackContext.self, forKey: .packContext); matchedLifeStage = try c.decodeIfPresent(SpeciesLifeStage.self, forKey: .matchedLifeStage)
    }
}
