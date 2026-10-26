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
    /// The selected region was retired. Its suggested replacement is offered, never
    /// applied until the person chooses it; any other region can be chosen too.
    case selectedRegionRetired(RetiredRegionRecovery)
    /// No region has a reviewed pack.
    case noReviewedCatalogue

    var pack: OfflineIdentificationPackMetadata? {
        if case .loaded(let pack) = self { return pack }
        return nil
    }

    /// True when the stored region cannot be searched but another region can.
    var isSelectedRegionUnavailable: Bool {
        switch self {
        case .selectedRegionUnavailable, .selectedRegionRetired: true
        case .notLoaded, .loaded, .loadFailed, .noReviewedCatalogue: false
        }
    }

    /// True when at least one reviewed pack exists to choose from.
    var canChangeRegion: Bool {
        switch self {
        case .loaded, .selectedRegionUnavailable, .selectedRegionRetired: true
        case .notLoaded, .loadFailed, .noReviewedCatalogue: false
        }
    }
}

struct RetiredRegionRecovery: Equatable, Sendable {
    let retiredName: String
    /// Nil when the replacement is not available in this build.
    let suggestion: OfflineIdentificationPackMetadata?

    var message: String {
        guard let suggestion else { return AppCopy.retiredDiveRegionMessage(retiredName) }
        return AppCopy.retiredDiveRegionMessage(retiredName, suggestion: suggestion.displayName)
    }
}

struct SelectedPackLoader: Sendable {
    let catalog: any MarineSpeciesCatalogRepository
    let regionRepository: any SelectedDiveRegionRepository
    var registry: RegionCatalogRegistry = .bundled

    func load() async -> SelectedPackState {
        let selectedID = await regionRepository.selectedRegion()
        do {
            let packs = try await catalog.availablePacks()
            if let pack = packs.first(where: { $0.id == selectedID }) { return .loaded(pack) }
            if packs.isEmpty { return .noReviewedCatalogue }
            guard let retirement = registry.definition(for: selectedID)?.retirement else { return .selectedRegionUnavailable }
            return .selectedRegionRetired(RetiredRegionRecovery(
                retiredName: retirement.displayName,
                suggestion: packs.first { $0.id == retirement.suggestedReplacement }
            ))
        } catch {
            return .loadFailed
        }
    }

    /// Stores the region the person chose from a recovery suggestion, then reloads.
    func choose(_ id: OfflineIdentificationPackID) async -> SelectedPackState {
        await regionRepository.setSelectedRegion(id)
        return await load()
    }
}
