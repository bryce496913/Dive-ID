import Foundation

protocol MarineSpeciesCatalogRepository: Sendable {
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata]
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack
}

enum LocalCatalogError: Error, Equatable, Sendable {
    case resourceMissing
    case unreadableData
    case invalidData
    case unsupportedPack
    case unsupportedSchemaVersion
    case invalidPackVersion
    case countMismatch(expected: Int, actual: Int)
    case duplicateIdentifier
    case duplicateScientificName
    case duplicateCommonName
    case duplicateImageFilename
    case missingImage(UUID)
    case invalidImage(UUID)
    case imageTooLarge(UUID)
    case emptyImageAttribution
    case unsupportedImageLicense(String)
    case invalidSimilarSpeciesReference
    case selfSimilarSpeciesReference
    case emptyCommonName
    case emptyScientificName
    case emptySummary
    case emptyDistinguishingFeatures
    case emptyHabitatDescription
    case emptyGeographicRange
    case missingDataSource
    case negativeMeasurement
    case invalidMeasurementRange
    case unknownControlledVocabularyValue(String)
    case aliasCollidesWithCanonicalIdentity
}

extension MarineSpeciesCatalogRepository {
    func loadProfiles() async throws -> [LocalSpeciesProfile] { try await loadPack(id: .caribbean).profiles }
}
