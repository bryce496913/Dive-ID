struct RegionCatalogRegistry: Sendable {
    /// Listed in this order. Retired regions follow and are never listed; their records
    /// are not bundled (tests open them from DiveIDTests/Fixtures/IdentificationPacks).
    static let bundled = Self(definitions: [GlobalRegion.definition] + GlobalSubregions.definitions
                              + [CaribbeanRegion.definition, TropicalPacificRegion.definition])
    let definitions: [RegionCatalogDefinition]

    func definition(for id: OfflineIdentificationPackID) -> RegionCatalogDefinition? {
        definitions.first { $0.id == id }
    }
}
