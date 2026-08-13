import Foundation

struct RegionCatalogDefinition: Hashable, Sendable {
    let id: OfflineIdentificationPackID
    let displayName: String
    let resourceDirectory: String
    let creatureResourceName: String
    let manifestResourceName: String
    let imageSubdirectory: String
    let packVersion: Int
    let geographicScope: String
    let regionAliases: [String]

    init(id: OfflineIdentificationPackID, displayName: String, resourceDirectory: String,
         creatureResourceName: String = "Creatures", manifestResourceName: String = "PackManifest",
         imageSubdirectory: String = "Images", packVersion: Int, geographicScope: String,
         regionAliases: [String]) {
        self.id = id; self.displayName = displayName; self.resourceDirectory = resourceDirectory
        self.creatureResourceName = creatureResourceName; self.manifestResourceName = manifestResourceName
        self.imageSubdirectory = imageSubdirectory; self.packVersion = packVersion
        self.geographicScope = geographicScope; self.regionAliases = regionAliases
    }
}
