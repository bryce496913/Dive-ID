/// One worldwide catalogue. Location is a ranking signal within it, never a filter,
/// so the manifest declares no region aliases (see Docs/GlobalMarine4000ActivationPlan.md).
enum GlobalRegion {
    static let definition = RegionCatalogDefinition(
        id: .global,
        resourceDirectory: "Global",
        // Opened for Release on the owner's explicit approval (Bryce, 2026-10-23), once
        // every record was approved in batch review. Release still exposes only
        // verified records (Docs/GlobalBatchReview.md, "Release visibility").
        availableInRelease: true
    )
}
