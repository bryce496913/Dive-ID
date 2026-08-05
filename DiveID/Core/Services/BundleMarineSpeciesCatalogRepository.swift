import Foundation

actor BundleMarineSpeciesCatalogRepository: MarineSpeciesCatalogRepository {
    private let bundle: Bundle
    private let resourceName: String
    private var cachedProfiles: [LocalSpeciesProfile]?

    init(bundle: Bundle = .main, resourceName: String = "MarineSpeciesCatalog") {
        self.bundle = bundle
        self.resourceName = resourceName
    }

    func loadProfiles() async throws -> [LocalSpeciesProfile] {
        if let cachedProfiles { return cachedProfiles }
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            throw LocalCatalogError.resourceMissing
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LocalCatalogError.unreadableData }
        let profiles: [LocalSpeciesProfile]
        do { profiles = try JSONDecoder().decode([LocalSpeciesProfile].self, from: data) } catch { throw LocalCatalogError.invalidData }
        try Self.validate(profiles)
        let sorted = profiles.sorted { $0.commonName.localizedStandardCompare($1.commonName) == .orderedAscending }
        cachedProfiles = sorted
        return sorted
    }

    static func validate(_ profiles: [LocalSpeciesProfile]) throws {
        var ids = Set<UUID>()
        var scientificNames = Set<String>()
        var canonicalIdentities = Set<String>()
        for profile in profiles {
            guard ids.insert(profile.id).inserted else { throw LocalCatalogError.duplicateIdentifier }
            let commonName = normalizedIdentity(profile.commonName)
            let scientificName = normalizedIdentity(profile.scientificName)
            guard !commonName.isEmpty else { throw LocalCatalogError.emptyCommonName }
            guard !scientificName.isEmpty else { throw LocalCatalogError.emptyScientificName }
            guard scientificNames.insert(scientificName).inserted else { throw LocalCatalogError.duplicateScientificName }
            canonicalIdentities.insert(commonName)
            canonicalIdentities.insert(scientificName)
        }

        for profile in profiles {
            guard !profile.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalCatalogError.emptySummary }
            guard !profile.distinguishingFeatures.isEmpty, profile.distinguishingFeatures.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw LocalCatalogError.emptyDistinguishingFeatures }
            guard !profile.typicalHabitat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalCatalogError.emptyHabitatDescription }
            guard !profile.geographicRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalCatalogError.emptyGeographicRange }
            try validateRange(min: profile.minimumSizeCentimeters, max: profile.maximumSizeCentimeters)
            try validateRange(min: profile.minimumDepthMeters, max: profile.maximumDepthMeters)
            try validate(profile.categories, allowed: LocalObservationVocabulary.categories)
            try validate(profile.colors, allowed: LocalObservationVocabulary.colors)
            try validate(profile.markings, allowed: LocalObservationVocabulary.markings)
            try validate(profile.bodyShapes, allowed: LocalObservationVocabulary.bodyShapes)
            try validate(profile.habitats, allowed: LocalObservationVocabulary.habitats)
            try validate(profile.regions, allowed: LocalObservationVocabulary.regions)
            try validate(profile.behaviors, allowed: LocalObservationVocabulary.behaviors)
            let own = Set([normalizedIdentity(profile.commonName), normalizedIdentity(profile.scientificName)])
            for alias in profile.aliases.map(normalizedIdentity) where !alias.isEmpty && canonicalIdentities.contains(alias) && !own.contains(alias) {
                throw LocalCatalogError.aliasCollidesWithCanonicalIdentity
            }
        }
    }

    private static func normalizedIdentity(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private static func validateRange(min: Double?, max: Double?) throws {
        if let min, min < 0 { throw LocalCatalogError.negativeMeasurement }
        if let max, max < 0 { throw LocalCatalogError.negativeMeasurement }
        if let min, let max, min > max { throw LocalCatalogError.invalidMeasurementRange }
    }

    private static func validate(_ values: [String], allowed: Set<String>) throws {
        for value in values where !allowed.contains(value.lowercased()) { throw LocalCatalogError.unknownControlledVocabularyValue(value) }
    }
}
