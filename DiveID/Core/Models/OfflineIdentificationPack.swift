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
    /// Import accounting is not publication approval. These counts are emitted by
    /// the importer so catalogue/UI diagnostics can state that distinction.
    var includedRecordCount: Int? = nil
    var humanReviewedRecordCount: Int? = nil
    var publicationEligibleRecordCount: Int? = nil

    /// Missing accounting is deliberately treated as unapproved. A manifest is
    /// never allowed to imply publication approval merely by omitting counts.
    var isExperimental: Bool {
        guard let includedRecordCount, let humanReviewedRecordCount,
              let publicationEligibleRecordCount,
              includedRecordCount == speciesCount,
              humanReviewedRecordCount >= publicationEligibleRecordCount
        else { return true }
        return publicationEligibleRecordCount < speciesCount
    }

    var publicationStatusText: String {
        guard let includedRecordCount, let humanReviewedRecordCount,
              let publicationEligibleRecordCount,
              includedRecordCount == speciesCount,
              humanReviewedRecordCount >= publicationEligibleRecordCount
        else { return "Review accounting unavailable — not approved for publication" }
        if publicationEligibleRecordCount == 0 {
            return "0 of \(includedRecordCount) records approved for publication"
        }
        if publicationEligibleRecordCount == includedRecordCount {
            return "All \(includedRecordCount) records approved for publication"
        }
        return "\(publicationEligibleRecordCount) of \(includedRecordCount) records approved for publication"
    }
}

struct OfflineIdentificationPack: Sendable, Hashable {
    let metadata: OfflineIdentificationPackMetadata
    let profiles: [LocalSpeciesProfile]
}

enum RegionalOccurrenceStatus: String, Codable, Hashable, Sendable {
    /// Presence is supported, but the source does not establish abundance.
    case unknown
    case common, regular, occasional, rare, seasonal, introduced
}

enum SpeciesLifeStage: String, Codable, Hashable, Sendable {
    case juvenile, intermediate, adult, initialPhase, terminalPhase
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

struct RecordReview: Codable, Hashable, Sendable {
    let status: RecordReviewStatus
    let reviewerNotes: String?
    let reviewDate: Date?
    var verifiedBy: String? = nil
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

enum SpeciesMeasurementType: String, Codable, Hashable, Sendable {
    case totalLength, forkLength, discWidth, carapaceLength
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
