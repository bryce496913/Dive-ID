import DiveID
import Foundation

/// Builds the photo reference index for one pack from its bundled, approved photos.
/// Refuses to build when an approved photo is missing or carries a licence the photo
/// policy (Tools/SpeciesPhotos/photo_policy.json) doesn't allow.
public struct PhotoIndexBuilder {
    public struct Failure: Error, Equatable, CustomStringConvertible {
        public let problems: [String]
        public var description: String { "Photo index not built:\n" + problems.map { "- " + $0 }.joined(separator: "\n") }
    }

    /// One reference photo's record in the JSON sidecar.
    public struct SidecarEntry: Codable, Equatable {
        public let speciesID: String
        public let fileName: String
        public let sha256: String
        public let licence: String
    }

    /// Written next to the index. The stale-index check (Tools/CI/test_photo_index.py)
    /// recomputes every digest from the files in the repository.
    public struct Sidecar: Codable, Equatable {
        public let formatVersion: Int
        public let requestRevision: Int
        public let catalogueContentVersion: String
        public let speciesFile: String
        public let speciesFileSHA256: String
        public let dimension: Int
        public let count: Int
        public let indexSHA256: String
        public let entries: [SidecarEntry]
    }

    /// Display names in the catalogue → policy codes (Tools/SpeciesPhotos/licences.py).
    static let licenceCodes = [
        "CC0 1.0": "cc0", "CC BY 4.0": "cc-by", "CC BY-NC 4.0": "cc-by-nc", "CC BY-SA 4.0": "cc-by-sa",
        "CC BY-NC-SA 4.0": "cc-by-nc-sa", "CC BY-ND 4.0": "cc-by-nd", "CC BY-NC-ND 4.0": "cc-by-nc-nd",
    ]

    public let packDirectory: URL
    public let packID: String
    public let allowedLicences: Set<String>
    /// The feature print of one image file. Vision in the tool; a fake in tests; a candidate
    /// model's embedding in the model comparison.
    public let featurePrint: (URL) throws -> [Float]
    /// Recorded in the index header: the Vision request revision, or a candidate model's code.
    public let requestRevision: Int

    public init(packDirectory: URL, packID: String, policyURL: URL, requestRevision: Int = VisionFeaturePrint.requestRevision,
                featurePrint: @escaping (URL) throws -> [Float]) throws {
        self.requestRevision = requestRevision
        struct Policy: Decodable { let allowedLicences: [String] }
        self.packDirectory = packDirectory
        self.packID = packID
        allowedLicences = Set(try JSONDecoder().decode(Policy.self, from: Data(contentsOf: policyURL)).allowedLicences)
        self.featurePrint = featurePrint
    }

    /// The index and its sidecar. Nothing is written; the caller does that.
    public func build() throws -> (index: PhotoReferenceIndex, sidecar: Sidecar) {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: packDirectory.appendingPathComponent("PackManifest.json"))) as? [String: Any]
        guard let speciesName = manifest?["speciesResourceName"] as? String, let imageDirectory = manifest?["imageSubdirectory"] as? String else {
            throw Failure(problems: ["PackManifest.json: speciesResourceName and imageSubdirectory are required"])
        }
        let speciesFile = speciesName + ".json"
        let speciesData = try Data(contentsOf: packDirectory.appendingPathComponent(speciesFile))
        guard let records = try JSONSerialization.jsonObject(with: speciesData) as? [[String: Any]] else {
            throw Failure(problems: ["\(speciesFile): expected an array of records"])
        }

        var problems: [String] = []
        var photos: [(entry: PhotoReferenceIndex.Entry, url: URL, licence: String)] = []
        for record in records {
            guard let image = record["bundledImage"] as? [String: Any] else { continue }
            let id = record["id"] as? String ?? "?"
            guard let speciesID = UUID(uuidString: id), let fileName = image["fileName"] as? String, !fileName.isEmpty else {
                problems.append("species \(id): bundledImage needs a species UUID and a file name")
                continue
            }
            let licenceName = image["licenseName"] as? String ?? ""
            guard let code = Self.licenceCodes[licenceName], allowedLicences.contains(code) else {
                problems.append("species \(id), \(fileName): licence \(licenceName.isEmpty ? "(none)" : licenceName) is not allowed by photo_policy.json")
                continue
            }
            let url = packDirectory.appendingPathComponent(imageDirectory).appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                problems.append("species \(id): approved photo \(imageDirectory)/\(fileName) is missing")
                continue
            }
            photos.append((PhotoReferenceIndex.Entry(speciesID: speciesID, fileName: fileName), url, licenceName))
        }
        guard problems.isEmpty else { throw Failure(problems: problems) }
        guard !photos.isEmpty else { throw Failure(problems: ["\(speciesFile): no approved photos to index"]) }
        photos.sort { ($0.entry.speciesID.uuidString, $0.entry.fileName) < ($1.entry.speciesID.uuidString, $1.entry.fileName) }

        var vectors: [[Float]] = []
        var sidecarEntries: [SidecarEntry] = []
        for photo in photos {
            let data = try Data(contentsOf: photo.url)
            do { vectors.append(try featurePrint(photo.url)) }
            catch { throw Failure(problems: ["\(photo.entry.fileName): no feature print (\(error))"]) }
            sidecarEntries.append(SidecarEntry(speciesID: photo.entry.speciesID.uuidString, fileName: photo.entry.fileName,
                                               sha256: Self.sha256(data), licence: photo.licence))
        }
        guard let dimension = vectors.first?.count, vectors.allSatisfy({ $0.count == dimension }) else {
            throw Failure(problems: ["feature prints have different lengths"])
        }
        let index = try PhotoReferenceIndex(
            requestRevision: requestRevision,
            catalogueContentVersion: PhotoReferenceIndex.catalogueContentVersion(packID: packID, speciesData: speciesData),
            dimension: dimension, entries: photos.map(\.entry), vectors: vectors)
        let sidecar = Sidecar(formatVersion: Int(PhotoReferenceIndex.formatVersion), requestRevision: index.requestRevision,
                              catalogueContentVersion: index.catalogueContentVersion, speciesFile: speciesFile,
                              speciesFileSHA256: Self.sha256(speciesData), dimension: dimension, count: photos.count,
                              indexSHA256: Self.sha256(index.encoded()), entries: sidecarEntries)
        return (index, sidecar)
    }

    /// Writes the index (bundled with the app) and its sidecar (kept out of the app bundle).
    public static func write(_ index: PhotoReferenceIndex, _ sidecar: Sidecar, index indexURL: URL, sidecar sidecarURL: URL) throws {
        try index.encoded().write(to: indexURL, options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(sidecar) + Data("\n".utf8)).write(to: sidecarURL, options: .atomic)
    }

    static func sha256(_ data: Data) -> String { PhotoReferenceIndex.sha256Hex(data) }
}
