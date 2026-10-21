import Foundation
@testable import DiveID

struct ResultsCatalogRepository: MarineSpeciesCatalogRepository {
    var metadata: [OfflineIdentificationPackMetadata]
    var error: (any Error)?

    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] {
        if let error { throw error }
        return metadata
    }

    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        throw LocalCatalogError.unsupportedPack
    }
}

actor MutableSelectedDiveRegionRepository: SelectedDiveRegionRepository {
    private var region: OfflineIdentificationPackID

    init(initialRegion: OfflineIdentificationPackID) { region = initialRegion }
    func selectedRegion() async -> OfflineIdentificationPackID { region }
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async { region = id }
}
