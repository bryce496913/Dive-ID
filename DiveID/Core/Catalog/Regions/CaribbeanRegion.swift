/// Retired as a dive region (owner decision, 2026-10-26): its species are in Global and
/// Tropical Atlantic Regions. The pack stays bundled as a development evaluation fixture.
enum CaribbeanRegion {
    static let definition = RegionCatalogDefinition(
        id: .caribbean,
        resourceDirectory: "Caribbean",
        retirement: RegionRetirement(displayName: "Caribbean", suggestedReplacement: .tropicalAtlantic)
    )
}
