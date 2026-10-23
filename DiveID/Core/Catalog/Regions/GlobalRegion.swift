/// One worldwide catalogue. Location is a ranking signal within it, never a filter,
/// so the manifest declares no region aliases (see Docs/GlobalMarine4000ActivationPlan.md).
enum GlobalRegion {
    static let definition = RegionCatalogDefinition(
        id: .global,
        resourceDirectory: "Global",
        // Global stays out of Release even when batch approvals verify some of its
        // records. Enabling it is a separate change the owner approves explicitly
        // (Docs/GlobalBatchReview.md, "Release visibility").
        availableInRelease: false
    )
}
