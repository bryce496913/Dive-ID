/// Retired as a dive region (owner decision, 2026-10-26): its species are in Global and
/// Tropical Atlantic Regions. Only its ID and recovery remain in the app: a stored
/// "caribbean" selection offers Tropical Atlantic Regions, and saved identifications open
/// from their own snapshots. Its records are a test fixture
/// (DiveIDTests/Fixtures/IdentificationPacks/Caribbean) and are never bundled.
enum CaribbeanRegion {
    static let definition = RegionCatalogDefinition(
        id: .caribbean,
        resourceDirectory: "Caribbean",
        retirement: RegionRetirement(displayName: "Caribbean", suggestedReplacement: .tropicalAtlantic)
    )
}
