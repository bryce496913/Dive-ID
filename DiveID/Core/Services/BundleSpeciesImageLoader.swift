import Foundation

protocol SpeciesImageLoading: Sendable {
    func imageData(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID) async throws -> Data
}

enum SpeciesImageLoadingError: Error, Equatable, Sendable { case missingFile(String), corruptFile(String) }

actor BundleSpeciesImageLoader: SpeciesImageLoading {
    private let bundle: Bundle
    private let registry: RegionCatalogRegistry
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private var imageDirectories: [OfflineIdentificationPackID: String] = [:]
    private let limit = 12
    init(bundle: Bundle = .main, registry: RegionCatalogRegistry = .bundled) { self.bundle = bundle; self.registry = registry }
    func imageData(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID) async throws -> Data {
        let key = packID.rawValue + "/" + image.fileName
        if let cached = cache[key] { return cached }
        let ext = URL(fileURLWithPath: image.fileName).pathExtension
        let name = image.fileName.replacingOccurrences(of: "." + ext, with: "")
        guard let definition = registry.definition(for: packID) else { throw SpeciesImageLoadingError.missingFile(image.fileName) }
        let packDirectory = "IdentificationPacks/\(definition.resourceDirectory)"
        let imageDirectory: String
        if let cachedDirectory = imageDirectories[packID] {
            imageDirectory = cachedDirectory
        } else {
            guard let manifestURL = resourceURL(path: packDirectory + "/" + definition.manifestResourceName, withExtension: "json"),
                  let metadata = try? JSONDecoder().decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: manifestURL)),
                  metadata.id == packID
            else { throw SpeciesImageLoadingError.missingFile(image.fileName) }
            imageDirectory = metadata.imageSubdirectory
            imageDirectories[packID] = imageDirectory
        }
        let relativeDirectory = packDirectory + "/" + imageDirectory
        let path = relativeDirectory + "/" + name
        guard let url = resourceURL(path: path, withExtension: ext) else { throw SpeciesImageLoadingError.missingFile(image.fileName) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw SpeciesImageLoadingError.corruptFile(image.fileName) }
        cache[key] = data; order.append(key)
        while order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return data
    }

    private func resourceURL(path: String, withExtension ext: String) -> URL? {
        if let bundledURL = bundle.url(forResource: path, withExtension: ext) { return bundledURL }
        let sourceURL = URL(fileURLWithPath: "DiveID/Resources")
            .appendingPathComponent(path)
            .appendingPathExtension(ext)
        return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
    }
}
