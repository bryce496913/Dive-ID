/// One worldwide catalogue. Location is a ranking signal within it, never a filter,
/// so the manifest declares no region aliases (see Docs/GlobalMarine4000ActivationPlan.md).
enum GlobalRegion {
    static let definition = RegionCatalogDefinition(
        id: .global,
        resourceDirectory: "Global"
    )
}
