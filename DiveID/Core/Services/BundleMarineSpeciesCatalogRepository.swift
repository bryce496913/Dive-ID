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
        var names = Set<String>()
        for profile in profiles {
            guard ids.insert(profile.id).inserted else { throw LocalCatalogError.duplicateIdentifier }
            let name = profile.scientificName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, names.insert(name).inserted else { throw LocalCatalogError.duplicateScientificName }
        }
    }
}
