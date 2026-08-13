import Foundation

struct RegionCatalogDefinition: Hashable, Sendable {
    let id: OfflineIdentificationPackID
    let resourceDirectory: String
    let manifestResourceName: String

    init(id: OfflineIdentificationPackID, resourceDirectory: String,
         manifestResourceName: String = "PackManifest") {
        self.id = id; self.resourceDirectory = resourceDirectory
        self.manifestResourceName = manifestResourceName
    }
}
