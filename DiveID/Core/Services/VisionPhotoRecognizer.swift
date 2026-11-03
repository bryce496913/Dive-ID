import Foundation
#if canImport(Vision)
import CoreML
import Vision
#endif

/// Apple Vision image feature prints at a pinned request revision. The index tool and the
/// app must use the same revision; the index records it and the app rejects any other.
public enum VisionFeaturePrint {
    /// `VNGenerateImageFeaturePrintRequestRevision2` (768 floats; macOS 14, iOS 17), run on the CPU.
    public static let requestRevision = 2

    public static var isAvailable: Bool {
#if canImport(Vision)
        true
#else
        false
#endif
    }

    /// The feature print of an encoded image (JPEG, PNG, HEIF), L2-normalized.
    public static func vector(imageData: Data) throws -> [Float] {
#if canImport(Vision)
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = requestRevision
        // CPU on the Mac that builds the index and in the simulator (which has no Neural Engine
        // context). The phone fails to load the CPU network (espresso error -2), so it uses Vision's default.
#if targetEnvironment(simulator)
        if let cpu = try? request.supportedComputeStageDevices[.main]?.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            request.setComputeDevice(cpu, for: .main)
        }
#endif
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, observation.elementType == .float else {
            throw PhotoIndexError.featurePrintUnavailable
        }
        let count = observation.elementCount
        let values = observation.data.withUnsafeBytes { raw in
            (0..<count).map { raw.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self) }
        }
        return PhotoReferenceIndex.normalized(values)
#else
        throw PhotoIndexError.featurePrintUnavailable
#endif
    }
}

/// Nearest-neighbour matching of the diver's photo against the bundled species photos.
struct VisionPhotoRecognizer: PhotoRecognizer {
    let index: PhotoReferenceIndex
    /// Species returned per query, best first, one per species.
    static let candidateLimit = 20
    /// Provisional (cosine 0, which no Vision feature print falls below). To be set from the
    /// development split by the rule in Data/Evaluation/PhotoProtocol.v1.json, never from the held-out set.
    static let abstainSimilarity = 0.5
    var abstainSimilarity: Double { Self.abstainSimilarity }

    var recognizerID: String { "vision-featureprint" }
    var version: String { "r\(index.requestRevision)/\(index.catalogueContentVersion)" }
    var coveredSpeciesIDs: Set<UUID> { index.coveredSpeciesIDs }
    var isPlaceholder: Bool { false }

    func recognize(_ photo: ProcessedPhoto, catalogueContentVersion: String) async throws -> PhotoRecognition {
        guard catalogueContentVersion == index.catalogueContentVersion else {
            throw PhotoIndexError.catalogueMismatch(index: index.catalogueContentVersion, app: catalogueContentVersion)
        }
        try Task.checkCancellation()
        let query = try VisionFeaturePrint.vector(imageData: photo.uploadData)
        try Task.checkCancellation()
        let matches = index.nearestSpecies(to: query, limit: Self.candidateLimit)
        return PhotoRecognition(candidates: matches.map {
            PhotoRecognitionCandidate(speciesID: $0.speciesID, similarity: .init(value: Double($0.cosine), scale: .cosine),
                                      evidence: .init(referenceID: "bundled:\($0.fileName)", referenceFileName: $0.fileName))
        })
    }
}

/// Loads the bundled reference index the first time photo identification is used, and
/// rejects it rather than guess when it doesn't match this app: another Vision request
/// revision, or a species file that changed since the index was built.
actor BundledPhotoIndexProvider: PhotoRecognizerProviding {
    /// Lowest cosine between a reference photo's print computed here and its print in the
    /// index. Owner decision, 2026-10-29: lowered from 0.995 because an iPhone 14 Pro computes
    /// slightly different prints from the Mac that builds the index (12 photos: median 0.992,
    /// minimum 0.937, every photo still ranked its own species first). The iOS simulator
    /// (median 0.29) is still refused. See Tools/PhotoIndex/README.md.
    static let parityCosine: Float = 0.9

    private let loadData: @Sendable () throws -> Data
    /// A reference photo's bytes by file name, for the parity check; nil skips the check.
    private let referencePhoto: (@Sendable (String) throws -> Data)?
    private var loaded: Result<PhotoReferenceIndex, PhotoIndexError>?
    /// How long the first load took, for measurement.
    private(set) var loadDuration: Duration?

    init(loadData: @escaping @Sendable () throws -> Data, referencePhoto: (@Sendable (String) throws -> Data)? = nil) {
        self.loadData = loadData
        self.referencePhoto = referencePhoto
    }

    /// The Global pack's index in the app bundle, checked against one of its photos on first use.
    static func bundled(_ bundle: Bundle = .main) -> BundledPhotoIndexProvider {
        BundledPhotoIndexProvider(loadData: {
            guard let url = bundle.url(forResource: "PhotoIndex", withExtension: "bin", subdirectory: "IdentificationPacks/Global") else {
                throw PhotoIndexError.missing
            }
            return try Data(contentsOf: url, options: .mappedIfSafe)
        }, referencePhoto: { fileName in
            guard let url = bundle.url(forResource: fileName, withExtension: nil, subdirectory: "IdentificationPacks/Global/Images") else {
                throw PhotoIndexError.missing
            }
            return try Data(contentsOf: url)
        })
    }

    /// Prints made here must match the Mac's, or every match would be wrong: compute the
    /// first reference photo's print and compare it with the index.
    static func checkParity(_ index: PhotoReferenceIndex, referencePhoto: (String) throws -> Data) throws {
        guard let entry = index.entries.first else { throw PhotoIndexError.malformed("empty") }
        let here = try VisionFeaturePrint.vector(imageData: referencePhoto(entry.fileName))
        guard here.count == index.dimension else { throw PhotoIndexError.featurePrintMismatch(cosine: 0) }
        let cosine = zip(here, index.vectors.prefix(index.dimension)).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        guard cosine >= parityCosine else { throw PhotoIndexError.featurePrintMismatch(cosine: cosine) }
    }

    func index() throws -> PhotoReferenceIndex {
        if let loaded { return try loaded.get() }
        let start = ContinuousClock.now
        let result: Result<PhotoReferenceIndex, PhotoIndexError>
        do {
            let index = try PhotoReferenceIndex.decode(try loadData())
            if let referencePhoto, index.requestRevision == VisionFeaturePrint.requestRevision {
                try Self.checkParity(index, referencePhoto: referencePhoto)
            }
            result = .success(index)
        } catch let error as PhotoIndexError {
            result = .failure(error)
        } catch {
            result = .failure(.missing)
        }
        loadDuration = ContinuousClock.now - start
        loaded = result
        return try result.get()
    }

    func recognizer(for pack: OfflineIdentificationPack) async throws -> (any PhotoRecognizer)? {
        let index = try index()
        guard index.requestRevision == VisionFeaturePrint.requestRevision else {
            throw PhotoIndexError.requestRevisionMismatch(index: index.requestRevision, app: VisionFeaturePrint.requestRevision)
        }
        let app = pack.photoCatalogueContentVersion
        // A pack from another species file (Caribbean, Tropical Pacific) isn't covered; the
        // same file with different content means the index is stale.
        guard Self.sourcePack(of: index.catalogueContentVersion) == Self.sourcePack(of: app) else { return nil }
        guard index.catalogueContentVersion == app else {
            throw PhotoIndexError.catalogueMismatch(index: index.catalogueContentVersion, app: app)
        }
        return VisionPhotoRecognizer(index: index)
    }

    private static func sourcePack(of version: String) -> Substring {
        version.lastIndex(of: "-").map { version[..<$0] } ?? Substring(version)
    }
}
