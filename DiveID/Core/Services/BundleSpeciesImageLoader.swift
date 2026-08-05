import Foundation

protocol SpeciesImageLoading: Sendable {
    func imageData(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID) async throws -> Data
}

enum SpeciesImageLoadingError: Error, Equatable, Sendable { case missingFile(String), corruptFile(String) }

actor BundleSpeciesImageLoader: SpeciesImageLoading {
    private let bundle: Bundle
    private var cache: [String: Data] = [:]
    private var order: [String] = []
    private let limit = 12
    init(bundle: Bundle = .main) { self.bundle = bundle }
    func imageData(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID) async throws -> Data {
        let key = packID.rawValue + "/" + image.fileName
        if let cached = cache[key] { return cached }
        let ext = URL(fileURLWithPath: image.fileName).pathExtension
        let name = image.fileName.replacingOccurrences(of: "." + ext, with: "")
        let path = "IdentificationPacks/Caribbean/Images/" + name
        let url = bundle.url(forResource: path, withExtension: ext) ?? URL(fileURLWithPath: "DiveID/Resources/IdentificationPacks/Caribbean/Images").appendingPathComponent(image.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SpeciesImageLoadingError.missingFile(image.fileName) }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw SpeciesImageLoadingError.corruptFile(image.fileName) }
        cache[key] = data; order.append(key)
        while order.count > limit { cache.removeValue(forKey: order.removeFirst()) }
        return data
    }
}
