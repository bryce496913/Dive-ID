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
}

struct IdentificationMatch: Identifiable, Hashable, Sendable {
    let id: UUID
    let species: Species
    let confidence: Double
}

enum IdentificationSource: Hashable, Sendable {
    case description(String)
    case photo
}

enum LoadState<Value> {
    case idle, loading, loaded(Value), empty, failed(String)
}
