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
    var regionalOccurrence: RegionalOccurrenceStatus = .regular
    var regionalOccurrenceNotes: String? = nil
    var subregions: [String] = []
    var appearanceVariants: [SpeciesAppearanceVariant] = []
    var similarSpecies: [SimilarSpeciesComparison] = []
    var bundledImage: BundledSpeciesImage? = nil
    var dataSources: [SpeciesDataSourceReference] = []

    var species: Species {
        Species(
            id: id,
            commonName: commonName,
            scientificName: scientificName,
            summary: summary,
            visualCharacteristics: distinguishingFeatures,
            habitat: typicalHabitat,
            geographicRange: geographicRange,
            imageAssetName: imageAssetName,
            bundledImage: bundledImage,
            packContext: nil,
            regionalOccurrence: regionalOccurrence.rawValue,
            appearanceVariants: appearanceVariants,
            similarSpecies: similarSpecies
        )
    }
}

extension LocalSpeciesProfile {
    enum CodingKeys: String, CodingKey { case id, commonName, scientificName, aliases, categories, colors, markings, bodyShapes, habitats, regions, behaviors, keywords, minimumSizeCentimeters, maximumSizeCentimeters, minimumDepthMeters, maximumDepthMeters, summary, distinguishingFeatures, typicalHabitat, geographicRange, cautions, imageAssetName, regionalOccurrence, regionalOccurrenceNotes, subregions, appearanceVariants, similarSpecies, bundledImage, dataSources }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); commonName = try c.decode(String.self, forKey: .commonName); scientificName = try c.decode(String.self, forKey: .scientificName)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []; categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []; colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? []; markings = try c.decodeIfPresent([String].self, forKey: .markings) ?? []; bodyShapes = try c.decodeIfPresent([String].self, forKey: .bodyShapes) ?? []; habitats = try c.decodeIfPresent([String].self, forKey: .habitats) ?? []; regions = try c.decodeIfPresent([String].self, forKey: .regions) ?? []; behaviors = try c.decodeIfPresent([String].self, forKey: .behaviors) ?? []; keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
        minimumSizeCentimeters = try c.decodeIfPresent(Double.self, forKey: .minimumSizeCentimeters); maximumSizeCentimeters = try c.decodeIfPresent(Double.self, forKey: .maximumSizeCentimeters); minimumDepthMeters = try c.decodeIfPresent(Double.self, forKey: .minimumDepthMeters); maximumDepthMeters = try c.decodeIfPresent(Double.self, forKey: .maximumDepthMeters)
        summary = try c.decode(String.self, forKey: .summary); distinguishingFeatures = try c.decodeIfPresent([String].self, forKey: .distinguishingFeatures) ?? []; typicalHabitat = try c.decode(String.self, forKey: .typicalHabitat); geographicRange = try c.decode(String.self, forKey: .geographicRange); cautions = try c.decodeIfPresent([String].self, forKey: .cautions) ?? []; imageAssetName = try c.decodeIfPresent(String.self, forKey: .imageAssetName)
        regionalOccurrence = try c.decodeIfPresent(RegionalOccurrenceStatus.self, forKey: .regionalOccurrence) ?? .regular; regionalOccurrenceNotes = try c.decodeIfPresent(String.self, forKey: .regionalOccurrenceNotes); subregions = try c.decodeIfPresent([String].self, forKey: .subregions) ?? []; appearanceVariants = try c.decodeIfPresent([SpeciesAppearanceVariant].self, forKey: .appearanceVariants) ?? []; similarSpecies = try c.decodeIfPresent([SimilarSpeciesComparison].self, forKey: .similarSpecies) ?? []; bundledImage = try c.decodeIfPresent(BundledSpeciesImage.self, forKey: .bundledImage); dataSources = try c.decodeIfPresent([SpeciesDataSourceReference].self, forKey: .dataSources) ?? []
    }
}
