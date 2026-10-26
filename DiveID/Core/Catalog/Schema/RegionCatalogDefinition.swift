import Foundation

struct RegionCatalogDefinition: Hashable, Sendable {
    let id: OfflineIdentificationPackID
    let resourceDirectory: String
    let manifestResourceName: String
    /// Pack-level Release gate. When false, Release (publication access) never lists or
    /// opens this pack, whatever its records' review status; Debug and Internal still
    /// open it. Approved records alone therefore never publish a gated pack.
    let availableInRelease: Bool
    /// A region whose records are a subset of another pack's, listed by record ID in
    /// this region's species resource (`RegionMembership`). The records, their review
    /// status and their search data are the source pack's, unchanged.
    let derivedFrom: OfflineIdentificationPackID?
    /// A region no longer offered. It is never listed in any build and never opens in
    /// Release; Debug, Internal and tests can still open it by ID as an evaluation fixture.
    let retirement: RegionRetirement?

    init(id: OfflineIdentificationPackID, resourceDirectory: String,
         manifestResourceName: String = "PackManifest", availableInRelease: Bool = true,
         derivedFrom: OfflineIdentificationPackID? = nil, retirement: RegionRetirement? = nil) {
        self.id = id; self.resourceDirectory = resourceDirectory
        self.manifestResourceName = manifestResourceName
        self.availableInRelease = availableInRelease
        self.derivedFrom = derivedFrom
        self.retirement = retirement
    }

    var isListed: Bool { retirement == nil }
}

/// What a person whose stored dive region was retired is offered instead. The app
/// suggests the replacement and switches only when they choose it.
struct RegionRetirement: Hashable, Sendable {
    let displayName: String
    let suggestedReplacement: OfflineIdentificationPackID
}

/// The species resource of a derived region: the source pack's record IDs it keeps.
/// Written by Tools/FishBaseIntake/derive_regions.py.
struct RegionMembership: Decodable, Sendable {
    let sourcePackID: OfflineIdentificationPackID
    let speciesIDs: [UUID]
}
