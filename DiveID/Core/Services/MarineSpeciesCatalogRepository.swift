import Foundation

protocol MarineSpeciesCatalogRepository: Sendable {
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata]
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack
}

enum LocalCatalogError: Error, Equatable, Sendable {
    case resourceMissing
    case unreadableData
    case invalidData
    case unsupportedPack
    case unsupportedSchemaVersion
    case invalidPackVersion
    case countMismatch(expected: Int, actual: Int)
    case duplicateIdentifier
    case duplicateScientificName
    case duplicateCommonName
    case duplicateImageFilename
    case missingImage(UUID)
    case invalidImage(UUID)
    case imageTooLarge(UUID)
    case emptyImageAttribution
    case unsupportedImageLicense(String)
    case invalidSimilarSpeciesReference
    case selfSimilarSpeciesReference
    case emptyCommonName
    case emptyScientificName
    case emptySummary
    case emptyDistinguishingFeatures
    case emptyHabitatDescription
    case emptyGeographicRange
    case missingDataSource
    case unverifiedRecord
    case negativeMeasurement
    case invalidMeasurementRange
    case unknownControlledVocabularyValue(String)
    case aliasCollidesWithCanonicalIdentity
}

enum CatalogueDiagnosticCode: String, Equatable, Sendable {
    case manifestMissing = "CATALOG_MANIFEST_MISSING"
    case speciesResourceMissing = "CATALOG_SPECIES_RESOURCE_MISSING"
    case decodeFailed = "CATALOG_DECODE_FAILED"
    case countMismatch = "CATALOG_COUNT_MISMATCH"
    case vocabularyInvalid = "CATALOG_VOCABULARY_INVALID"
    case artworkMissing = "CATALOG_ARTWORK_MISSING"
    case artworkInvalid = "CATALOG_ARTWORK_INVALID"
    case validationFailed = "CATALOG_VALIDATION_FAILED"
    case unsupportedPack = "CATALOG_UNSUPPORTED_PACK"
}

enum CatalogueLoadPhase: String, Equatable, Sendable {
    case manifest, speciesResource, decoding, validation, artworkValidation
}

struct CatalogueLoadFailure: Error, Equatable, Sendable {
    let packID: OfflineIdentificationPackID
    let code: CatalogueDiagnosticCode
    let catalogError: LocalCatalogError?
    /// A bundle-relative resource name. This must never contain a local filesystem path.
    let resource: String?
    let phase: CatalogueLoadPhase
}

protocol CatalogueDiagnosticsReporting: Sendable {
    func record(_ failure: CatalogueLoadFailure) async
}

actor LocalCatalogueDiagnosticsReporter: CatalogueDiagnosticsReporting {
    static let shared = LocalCatalogueDiagnosticsReporter()
    private(set) var failures: [CatalogueLoadFailure] = []

    func record(_ failure: CatalogueLoadFailure) {
        failures.append(failure)
    }
}

extension MarineSpeciesCatalogRepository {
    func loadProfiles() async throws -> [LocalSpeciesProfile] { try await loadPack(id: .caribbean).profiles }
}
