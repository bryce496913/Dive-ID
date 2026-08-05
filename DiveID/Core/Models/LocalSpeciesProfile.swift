import Foundation

struct LocalSpeciesProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let commonName: String
    let scientificName: String
    let aliases: [String]
    let categories: [String]
    let colors: [String]
    let markings: [String]
    let bodyShapes: [String]
    let habitats: [String]
    let regions: [String]
    let behaviors: [String]
    let keywords: [String]
    let minimumSizeCentimeters: Double?
    let maximumSizeCentimeters: Double?
    let minimumDepthMeters: Double?
    let maximumDepthMeters: Double?
    let summary: String
    let distinguishingFeatures: [String]
    let typicalHabitat: String
    let geographicRange: String
    let cautions: [String]
    let imageAssetName: String?

    var species: Species {
        Species(
            id: id,
            commonName: commonName,
            scientificName: scientificName,
            summary: summary,
            visualCharacteristics: distinguishingFeatures,
            habitat: typicalHabitat,
            geographicRange: geographicRange,
            imageAssetName: imageAssetName
        )
    }
}
