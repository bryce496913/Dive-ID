import Foundation

/// Stable, extensible identifier for an offline catalogue. Region identifiers are data,
/// rather than enum cases, so introducing a pack does not require editing shared code.
struct OfflineIdentificationPackID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    static let caribbean = Self(rawValue: "caribbean")
    static let tropicalPacific = Self(rawValue: "tropical-pacific")
    static let global = Self(rawValue: "global")
    static let tropicalAtlantic = Self(rawValue: "tropical-atlantic")
    static let indoPacific = Self(rawValue: "indo-pacific")
    static let pacificCoast = Self(rawValue: "pacific-coast")
    static let mediterranean = Self(rawValue: "mediterranean")
}

struct OfflineIdentificationPackMetadata: Identifiable, Codable, Hashable, Sendable {
    let id: OfflineIdentificationPackID
    let schemaVersion: Int
    let packVersion: Int
    let displayName: String
    let shortDescription: String
    let geographicScope: String
    let regionAliases: [String]
    var speciesCount: Int
    let speciesResourceName: String
    let imageSubdirectory: String
    let includedWithApp: Bool
    let lastDataReviewDate: Date?
    /// Source-pack accounting, emitted before any configuration-specific filtering.
    /// `includedRecordCount` is the full pack, `publicationEligibleRecordCount` is
    /// its approved subset, and `speciesCount` is the subset exposed by this value.
    /// Records not publication-eligible are drafts for publication purposes.
    var includedRecordCount: Int? = nil
    var humanReviewedRecordCount: Int? = nil
    var publicationEligibleRecordCount: Int? = nil

    var approvedRecordCount: Int? { publicationEligibleRecordCount }
    var draftRecordCount: Int? {
        guard let includedRecordCount, let publicationEligibleRecordCount,
              publicationEligibleRecordCount <= includedRecordCount else { return nil }
        return includedRecordCount - publicationEligibleRecordCount
    }
    var availableRecordCount: Int { speciesCount }

    /// Accounting is valid when source counts are ordered and the exposed records
    /// are either the complete development pack or exactly its approved subset.
    private var hasValidPublicationAccounting: Bool {
        guard let includedRecordCount, let humanReviewedRecordCount,
              let publicationEligibleRecordCount,
              includedRecordCount >= 0,
              publicationEligibleRecordCount >= 0,
              humanReviewedRecordCount >= publicationEligibleRecordCount,
              humanReviewedRecordCount <= includedRecordCount,
              publicationEligibleRecordCount <= includedRecordCount
        else { return false }
        return speciesCount == includedRecordCount || speciesCount == publicationEligibleRecordCount
    }

    /// Missing or inconsistent accounting is deliberately treated as unapproved, and so
    /// is an empty pack: having no records is not the same as every record being approved.
    var isExperimental: Bool {
        guard hasValidPublicationAccounting, let publicationEligibleRecordCount, includedRecordCount != 0 else { return true }
        return speciesCount > publicationEligibleRecordCount
    }

    var publicationStatusText: String {
        guard hasValidPublicationAccounting,
              let includedRecordCount, let publicationEligibleRecordCount,
              let draftRecordCount
        else { return "Review accounting unavailable — not approved for publication" }
        if includedRecordCount == 0 { return "No records yet — not approved for publication" }
        if publicationEligibleRecordCount == includedRecordCount {
            return "All \(speciesCount) available records approved for publication"
        }
        if speciesCount == publicationEligibleRecordCount {
            return "\(publicationEligibleRecordCount) approved \(publicationEligibleRecordCount == 1 ? "record" : "records") available (\(draftRecordCount) draft \(draftRecordCount == 1 ? "record" : "records") excluded)"
        }
        return "\(speciesCount) records available — \(publicationEligibleRecordCount) approved and \(draftRecordCount) draft"
    }
}

struct OfflineIdentificationPack: Sendable, Hashable {
    let metadata: OfflineIdentificationPackMetadata
    let profiles: [LocalSpeciesProfile]
    /// Hash of the profiles, computed once when the pack is built, so search caches
    /// can key on content without rehashing every profile on each query. In-process only.
    let contentFingerprint: Int
    /// A digest of the catalogue resource this pack was decoded from and of how it was
    /// filtered, stable across launches (unlike `contentFingerprint`, which uses the
    /// per-process seeded `Hasher`). Set by the catalogue repository; nil for packs
    /// assembled in memory, whose search index is then never persisted.
    let persistentContentKey: String?

    init(metadata: OfflineIdentificationPackMetadata, profiles: [LocalSpeciesProfile], persistentContentKey: String? = nil) {
        self.metadata = metadata
        self.profiles = profiles
        self.persistentContentKey = persistentContentKey
        var hasher = Hasher()
        hasher.combine(profiles)
        contentFingerprint = hasher.finalize()
        groupNames = Self.groupNames(in: profiles)
    }

    /// Normalized aliases that name a group in this pack rather than one species: the head
    /// noun of any multi-word common name ("surgeonfish" from "Twospot surgeonfish"), and
    /// any alias carried by more than one record ("coral trout", "grouper").
    let groupNames: Set<String>

    static func groupNames(in profiles: [LocalSpeciesProfile]) -> Set<String> {
        var names = Set<String>()
        var aliasOwners: [String: Int] = [:]
        for profile in profiles {
            let words = LocalObservationParser.normalize(profile.commonName).split(separator: " ")
            if words.count > 1, let head = words.last { names.insert(String(head)) }
            for alias in Set(profile.aliases.map(LocalObservationParser.normalize)) { aliasOwners[alias, default: 0] += 1 }
        }
        names.formUnion(aliasOwners.filter { $0.value > 1 }.keys)
        return names
    }
}

enum RegionalOccurrenceStatus: String, Codable, Hashable, Sendable {
    /// Presence is supported, but the source does not establish abundance.
    case unknown
    case common, regular, occasional, rare, seasonal, introduced
}

/// A life stage or sex with its own appearance (males and females can differ).
enum SpeciesLifeStage: String, Codable, Hashable, Sendable {
    case juvenile, intermediate, adult, initialPhase, terminalPhase, male, female
}

struct SpeciesAppearanceVariant: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let lifeStage: SpeciesLifeStage
    let colors: [String]
    let markings: [String]
    let bodyShapes: [String]
    let minimumSizeCentimeters: Double?
    let maximumSizeCentimeters: Double?
    let description: String
    let distinguishingFeatures: [String]
}

struct SimilarSpeciesComparison: Codable, Hashable, Sendable {
    let speciesID: UUID
    let distinguishingText: String
}

struct BundledSpeciesImage: Codable, Hashable, Sendable {
    let fileName: String
    let alternativeText: String
    let creatorName: String
    let sourceName: String
    let sourceURL: String
    let licenseName: String
    let licenseURL: String
}

struct SpeciesDataSourceReference: Codable, Hashable, Sendable {
    var stableSourceID: String? = nil
    let sourceName: String
    let sourceURL: String
    var citationReference: String? = nil
    let reviewedFields: [String]
    let accessedDate: Date?
    var sourceLicense: String? = nil
}

enum RecordReviewStatus: String, Codable, Hashable, Sendable { case draft, sourceChecked, verified }

/// How a verified record was approved in batch review (Tools/CatalogReview/global_batches.py).
enum RecordReviewMethod: String, Codable, Hashable, Sendable {
    case individuallyReviewed = "individually-reviewed"
    case sampleApproved = "sample-approved"
}

struct RecordReview: Codable, Hashable, Sendable {
    let status: RecordReviewStatus
    let reviewerNotes: String?
    let reviewDate: Date?
    var verifiedBy: String? = nil
    var reviewMethod: RecordReviewMethod? = nil
}

struct SpeciesTaxonomy: Codable, Hashable, Sendable {
    let wormsAphiaID: Int?
    let scientificNameAuthority: String?
    let taxonomicClass: String?
    let order: String?
    let family: String?
    let genus: String?
    let acceptedScientificName: String
    let sourceScientificName: String
}

/// Length bases used by FishBase (TL, SL, FL, WD) and SeaLifeBase (CL, CW, SHL, ML, BL, DL).
enum SpeciesMeasurementType: String, Codable, Hashable, Sendable {
    case totalLength, standardLength, forkLength, discWidth, discLength
    case carapaceLength, carapaceWidth, shellLength, mantleLength, bodyLength

    /// Widths are not lengths: a described length is never compared with them.
    var isWidth: Bool { self == .discWidth || self == .carapaceWidth }
}

struct SpeciesMeasurements: Codable, Hashable, Sendable {
    let typicalObservedMinimumCentimeters: Double?
    let typicalObservedMaximumCentimeters: Double?
    let maximumRecordedCentimeters: Double?
    let type: SpeciesMeasurementType
}

enum ObservationInformationLevel: String, Codable, Hashable, Sendable { case sufficient, limited, insufficient }

struct PackContext: Codable, Hashable, Sendable {
    let packID: OfflineIdentificationPackID
    let displayName: String
    let packVersion: Int
}
