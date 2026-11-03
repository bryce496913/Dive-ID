import Foundation

// MARK: Recognizer boundary

/// The scale a recognizer's similarity is on. Values are normalized to 0–1 before use
/// (Docs/HybridRankingContract.md#photo-evidence); raw values are never compared across scales.
enum PhotoSimilarityScale: String, Codable, Hashable, Sendable {
    /// −1…1, as from an image-embedding cosine.
    case cosine
    /// Already 0…1.
    case unitInterval
}

struct PhotoSimilarity: Hashable, Sendable {
    let value: Double
    let scale: PhotoSimilarityScale

    /// 0…1, the same transform as semantic retrieval for cosine.
    var normalized: Double {
        guard value.isFinite else { return 0 }
        switch scale {
        case .cosine: return min(max((value + 1) / 2, 0), 1)
        case .unitInterval: return min(max(value, 0), 1)
        }
    }
}

/// Which reference photo a candidate matched. Stored with the match, never the diver's photo.
struct PhotoMatchEvidence: Codable, Hashable, Sendable {
    /// The recognizer's stable ID for the reference image.
    let referenceID: String
    /// The bundled image's file name, when the reference is one of the catalogue's photos.
    var referenceFileName: String? = nil
}

/// Which recognizer produced a photo result, kept with the result and with a saved sighting.
struct PhotoRecognizerInfo: Codable, Hashable, Sendable {
    let recognizerID: String
    let recognizerVersion: String
    /// A test recognizer: the result is a placeholder, not a real match.
    let isPlaceholder: Bool
}

struct PhotoRecognitionCandidate: Hashable, Sendable {
    let speciesID: UUID
    let similarity: PhotoSimilarity
    let evidence: PhotoMatchEvidence
}

struct PhotoRecognition: Hashable, Sendable {
    /// Best first. May include species outside the searched pack; the service drops those.
    let candidates: [PhotoRecognitionCandidate]
    /// The recognizer declined to suggest anything (for example an unusable photo).
    var abstained = false
}

enum PhotoRecognitionError: Error, Equatable, Sendable {
    /// The recognizer's reference index was built for a different catalogue.
    case catalogueVersionMismatch(expected: String, actual: String)
}

/// Turns a prepared photo into ranked species candidates. Swappable: a test stub now, a
/// Core ML model with a reference index later. It runs only on the device.
protocol PhotoRecognizer: Sendable {
    var recognizerID: String { get }
    var version: String { get }
    /// Species the recognizer can suggest (those with reference photos).
    var coveredSpeciesIDs: Set<UUID> { get }
    /// True for test and preview recognizers whose results are placeholders.
    var isPlaceholder: Bool { get }
    /// Normalized similarity below which the photo abstains. Each recognizer's own, set from
    /// development data (Data/Evaluation/PhotoProtocol.v1.json); the shared provisional value otherwise.
    var abstainSimilarity: Double { get }
    func recognize(_ photo: ProcessedPhoto, catalogueContentVersion: String) async throws -> PhotoRecognition
}

extension PhotoRecognizer {
    var abstainSimilarity: Double { PhotoMatchingWeights.abstainSimilarity }
}

/// Supplies a recognizer for a loaded pack, or nil when none is available for it.
protocol PhotoRecognizerProviding: Sendable {
    func recognizer(for pack: OfflineIdentificationPack) async throws -> (any PhotoRecognizer)?
}

extension OfflineIdentificationPack {
    /// Identifies the catalogue content a reference index must match: the species file the
    /// pack (or its source pack) was loaded from; for packs built in memory, its ID and version.
    var photoCatalogueContentVersion: String {
        photoReferenceVersion ?? persistentContentKey ?? "\(metadata.id.rawValue)-v\(metadata.packVersion)"
    }
}

// MARK: Test recognizer

/// A deterministic recognizer for tests, previews and Debug/Internal builds until a real
/// model exists. Its results are placeholders, never identifications.
struct StubPhotoRecognizer: PhotoRecognizer {
    let recognizerID: String
    let version: String
    let coveredSpeciesIDs: Set<UUID>
    let catalogueContentVersion: String?
    private let respond: @Sendable (ProcessedPhoto) -> PhotoRecognition
    private let delay: Duration
    var isPlaceholder: Bool { true }

    /// Always returns `recognition`. `catalogueContentVersion` nil accepts any catalogue.
    init(recognition: PhotoRecognition, coveredSpeciesIDs: Set<UUID>, recognizerID: String = "stub",
         version: String = "1", catalogueContentVersion: String? = nil, delay: Duration = .zero) {
        self.init(coveredSpeciesIDs: coveredSpeciesIDs, recognizerID: recognizerID, version: version,
                  catalogueContentVersion: catalogueContentVersion, delay: delay) { _ in recognition }
    }

    init(coveredSpeciesIDs: Set<UUID>, recognizerID: String = "stub", version: String = "1",
         catalogueContentVersion: String? = nil, delay: Duration = .zero,
         respond: @escaping @Sendable (ProcessedPhoto) -> PhotoRecognition) {
        self.recognizerID = recognizerID
        self.version = version
        self.coveredSpeciesIDs = coveredSpeciesIDs
        self.catalogueContentVersion = catalogueContentVersion
        self.delay = delay
        self.respond = respond
    }

    func recognize(_ photo: ProcessedPhoto, catalogueContentVersion: String) async throws -> PhotoRecognition {
        if let expected = self.catalogueContentVersion, expected != catalogueContentVersion {
            throw PhotoRecognitionError.catalogueVersionMismatch(expected: expected, actual: catalogueContentVersion)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        return respond(photo)
    }

    /// The same photo always gives the same five species among those with a bundled photo,
    /// at fixed similarities 0.92, 0.84, 0.76, 0.68 and 0.60.
    static func deterministic(for pack: OfflineIdentificationPack) -> StubPhotoRecognizer {
        let references = pack.profiles.filter { $0.bundledImage != nil }.sorted { $0.id.uuidString < $1.id.uuidString }
        return StubPhotoRecognizer(coveredSpeciesIDs: Set(references.map(\.id)), recognizerID: "stub-deterministic",
                                   catalogueContentVersion: pack.photoCatalogueContentVersion) { photo in
            guard !references.isEmpty else { return PhotoRecognition(candidates: [], abstained: true) }
            let start = Int(StableDigest.fnv1a64(photo.uploadData) % UInt64(references.count))
            let similarities = [0.92, 0.84, 0.76, 0.68, 0.60]
            let picked = (0..<min(similarities.count, references.count)).map { references[(start + $0 * 7) % references.count] }
            var seen = Set<UUID>()
            let unique = picked.filter { seen.insert($0.id).inserted }
            return PhotoRecognition(candidates: zip(unique, similarities).map { profile, similarity in
                PhotoRecognitionCandidate(speciesID: profile.id, similarity: .init(value: similarity, scale: .unitInterval),
                                          evidence: .init(referenceID: "bundled:\(profile.id.uuidString)",
                                                          referenceFileName: profile.bundledImage?.fileName))
            })
        }
    }
}

/// Gives every pack the deterministic stub recognizer.
struct StubPhotoRecognizerProvider: PhotoRecognizerProviding {
    func recognizer(for pack: OfflineIdentificationPack) async throws -> (any PhotoRecognizer)? {
        StubPhotoRecognizer.deterministic(for: pack)
    }
}

/// Follows the optional-model pattern of the semantic encoder: the bundled recognizer
/// when one is configured, otherwise the fallback. A bundled recognizer that is present
/// but rejected (stale index, other request revision) throws: it never falls back to
/// other results.
struct ConfiguredPhotoRecognizerProvider: PhotoRecognizerProviding {
    let bundled: (any PhotoRecognizerProviding)?
    let fallback: (any PhotoRecognizerProviding)?

    func recognizer(for pack: OfflineIdentificationPack) async throws -> (any PhotoRecognizer)? {
        if let bundled { return try await bundled.recognizer(for: pack) }
        return try await fallback?.recognizer(for: pack)
    }
}
