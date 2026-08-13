struct RegionCatalogRegistry: Sendable {
    static let bundled = Self(definitions: [CaribbeanRegion.definition])
    let definitions: [RegionCatalogDefinition]

    func definition(for id: OfflineIdentificationPackID) -> RegionCatalogDefinition? {
        definitions.first { $0.id == id }
    }
}
