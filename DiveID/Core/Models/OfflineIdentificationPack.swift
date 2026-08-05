import Foundation

enum OfflineIdentificationPackID: String, Codable, Hashable, Sendable, CaseIterable { case caribbean }

struct OfflineIdentificationPackMetadata: Identifiable, Codable, Hashable, Sendable {
    let id: OfflineIdentificationPackID
    let schemaVersion: Int
    let packVersion: Int
    let displayName: String
    let shortDescription: String
    let geographicScope: String
    let regionAliases: [String]
    let speciesCount: Int
    let speciesResourceName: String
    let imageSubdirectory: String
    let includedWithApp: Bool
    let lastDataReviewDate: Date?
}

struct OfflineIdentificationPack: Sendable, Hashable {
    let metadata: OfflineIdentificationPackMetadata
    let profiles: [LocalSpeciesProfile]
}

enum RegionalOccurrenceStatus: String, Codable, Hashable, Sendable {
    case common, regular, occasional, rare, seasonal, introduced
}

enum SpeciesLifeStage: String, Codable, Hashable, Sendable {
    case juvenile, intermediate, adult, initialPhase, terminalPhase
}

struct SpeciesAppearanceVariant: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let lifeStage: SpeciesLifeStage
    let colors: [String]
    let markings: [String]
    let bodyShapes: [String]
    let minimumSizeCentimeters: Double?
    let maximumSizeCentimeters: Double?
    let description: String
    let distinguishingFeatures: [String]
}

struct SimilarSpeciesComparison: Codable, Hashable, Sendable {
    let speciesID: UUID
    let distinguishingText: String
}

struct BundledSpeciesImage: Codable, Hashable, Sendable {
    let fileName: String
    let alternativeText: String
    let creatorName: String
    let sourceName: String
    let sourceURL: String
    let licenseName: String
    let licenseURL: String
}

struct SpeciesDataSourceReference: Codable, Hashable, Sendable {
    let sourceName: String
    let sourceURL: String
    let reviewedFields: [String]
    let accessedDate: Date?
}

enum ObservationInformationLevel: String, Codable, Hashable, Sendable { case sufficient, limited, insufficient }

struct PackContext: Codable, Hashable, Sendable {
    let packID: OfflineIdentificationPackID
    let displayName: String
    let packVersion: Int
}
