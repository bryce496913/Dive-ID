import Foundation

/// Catalogue availability for the persisted dive region. Home and Describe What
/// You Saw both load and present the selected region through this one type.
enum SelectedPackState: Equatable, Sendable {
    /// No load has completed yet.
    case notLoaded
    case loaded(OfflineIdentificationPackMetadata)
    case loadFailed
    /// The selected region has no reviewed pack, but another region does.
    case selectedRegionUnavailable
    /// No region has a reviewed pack.
    case noReviewedCatalogue

    var pack: OfflineIdentificationPackMetadata? {
        if case .loaded(let pack) = self { return pack }
        return nil
    }

    /// True when at least one reviewed pack exists to choose from.
    var canChangeRegion: Bool {
        switch self {
        case .loaded, .selectedRegionUnavailable: true
        case .notLoaded, .loadFailed, .noReviewedCatalogue: false
        }
    }
}

struct SelectedPackLoader: Sendable {
    let catalog: any MarineSpeciesCatalogRepository
    let regionRepository: any SelectedDiveRegionRepository

    func load() async -> SelectedPackState {
        let selectedID = await regionRepository.selectedRegion()
        do {
            let packs = try await catalog.availablePacks()
            if let pack = packs.first(where: { $0.id == selectedID }) { return .loaded(pack) }
            return packs.isEmpty ? .noReviewedCatalogue : .selectedRegionUnavailable
        } catch {
            return .loadFailed
        }
    }
}
