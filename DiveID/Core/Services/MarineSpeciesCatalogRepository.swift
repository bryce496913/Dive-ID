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
}
