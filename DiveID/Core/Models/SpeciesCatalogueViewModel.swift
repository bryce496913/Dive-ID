import Foundation
import Observation

/// Every species in the selected dive region, for browsing without a search: name order,
/// filtered by name as the person types, optionally only those with a photo.
@MainActor @Observable
final class SpeciesCatalogueViewModel {
    var packState: SelectedPackState = .notLoaded
    private(set) var species: [Species] = []
    private(set) var isLoading = false
    var errorMessage: String?
    var searchText = ""
    var photosOnly = false
    private let packLoader: SelectedPackLoader

    init(catalog: any MarineSpeciesCatalogRepository, regionRepository: any SelectedDiveRegionRepository) {
        packLoader = SelectedPackLoader(catalog: catalog, regionRepository: regionRepository)
    }

    var pack: OfflineIdentificationPackMetadata? { packState.pack }
    var photoCount: Int { species.filter(\.hasPhoto).count }

    /// The species to show: those whose common name, scientific name or another name
    /// contains every typed word, in name order.
    var visibleSpecies: [Species] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return species.filter { item in
            guard !photosOnly || item.hasPhoto else { return false }
            guard !words.isEmpty else { return true }
            let names = ([item.commonName, item.scientificName] + item.aliases).joined(separator: " ").lowercased()
            return words.allSatisfy(names.contains)
        }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        packState = await packLoader.load()
        guard let metadata = pack else { species = []; return }
        do {
            let loaded = try await packLoader.catalog.loadPack(id: metadata.id)
            let context = PackContext(packID: metadata.id, displayName: metadata.displayName, packVersion: metadata.packVersion)
            species = loaded.profiles.map { profile in
                var value = profile.species
                value.packContext = context  // so a derived region shows Global's photos
                return value
            }
            .sorted { $0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending }
            errorMessage = nil
        } catch {
            species = []
            errorMessage = "The species list could not be loaded. Please try again."
        }
    }
}

extension Species {
    /// True when the species has an approved photo (not just placeholder artwork).
    var hasPhoto: Bool { bundledImage?.isPhoto == true }
}
