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
    private let limit = 12
    init(bundle: Bundle = .main, registry: RegionCatalogRegistry = .bundled) { self.bundle = bundle; self.registry = registry }
    func imageData(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID) async throws -> Data {
        let key = packID.rawValue + "/" + image.fileName
        if let cached = cache[key] { return cached }
        let ext = URL(fileURLWithPath: image.fileName).pathExtension
        let name = image.fileName.replacingOccurrences(of: "." + ext, with: "")
        guard let definition = registry.definition(for: packID) else { throw SpeciesImageLoadingError.missingFile(image.fileName) }
        let relativeDirectory = "IdentificationPacks/\(definition.resourceDirectory)/\(definition.imageSubdirectory)"
        let path = relativeDirectory + "/" + name
        let url = bundle.url(forResource: path, withExtension: ext) ?? URL(fileURLWithPath: "DiveID/Resources").appendingPathComponent(relativeDirectory).appendingPathComponent(image.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SpeciesImageLoadingError.missingFile(image.fileName) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw SpeciesImageLoadingError.corruptFile(image.fileName) }
        cache[key] = data; order.append(key)
        while order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return data
    }
}
