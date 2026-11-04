/// Retired as a dive region (owner decision, 2026-10-26) in favour of Indo-Pacific Regions,
/// drawn from Global. Only its ID and recovery remain in the app; its draft records are a
/// test fixture (DiveIDTests/Fixtures/IdentificationPacks/TropicalPacific), never bundled.
enum TropicalPacificRegion {
    static let definition = RegionCatalogDefinition(
        id: .tropicalPacific,
        resourceDirectory: "TropicalPacific",
        retirement: RegionRetirement(displayName: "Tropical Pacific", suggestedReplacement: .indoPacific)
    )
}
