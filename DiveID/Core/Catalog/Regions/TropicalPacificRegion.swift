/// Retired as a dive region (owner decision, 2026-10-26) in favour of Indo-Pacific Regions,
/// drawn from Global. The draft pack stays bundled as a development evaluation fixture.
enum TropicalPacificRegion {
    static let definition = RegionCatalogDefinition(
        id: .tropicalPacific,
        resourceDirectory: "TropicalPacific",
        retirement: RegionRetirement(displayName: "Tropical Pacific", suggestedReplacement: .indoPacific)
    )
}
