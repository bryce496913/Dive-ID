import Foundation

protocol MarineSpeciesCatalogRepository: Sendable {
    func loadProfiles() async throws -> [LocalSpeciesProfile]
}

enum LocalCatalogError: Error, Equatable, Sendable {
    case resourceMissing
    case unreadableData
    case invalidData
    case duplicateIdentifier
    case duplicateScientificName
    case emptyCommonName
    case emptyScientificName
    case emptySummary
    case emptyDistinguishingFeatures
    case emptyHabitatDescription
    case emptyGeographicRange
    case negativeMeasurement
    case invalidMeasurementRange
    case unknownControlledVocabularyValue(String)
    case aliasCollidesWithCanonicalIdentity
}
