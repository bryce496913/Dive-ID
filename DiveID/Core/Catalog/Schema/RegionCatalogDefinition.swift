import Foundation

struct RegionCatalogDefinition: Hashable, Sendable {
    let id: OfflineIdentificationPackID
    let resourceDirectory: String
    let manifestResourceName: String
    /// Pack-level Release gate. When false, Release (publication access) never lists or
    /// opens this pack, whatever its records' review status; Debug and Internal still
    /// open it. Approved records alone therefore never publish a gated pack.
    let availableInRelease: Bool

    init(id: OfflineIdentificationPackID, resourceDirectory: String,
         manifestResourceName: String = "PackManifest", availableInRelease: Bool = true) {
        self.id = id; self.resourceDirectory = resourceDirectory
        self.manifestResourceName = manifestResourceName
        self.availableInRelease = availableInRelease
    }
}
