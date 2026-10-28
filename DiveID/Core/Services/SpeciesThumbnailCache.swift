import ImageIO
import UIKit

/// Decoded, downsampled species photos for list rows. A row asks only when it appears; the
/// image is decoded straight to the row's pixel size with ImageIO (never at full size) and
/// kept in an NSCache, which the system trims under memory pressure. Bytes come from the
/// shared BundleSpeciesImageLoader, so a region derived from Global still finds its photos.
actor SpeciesThumbnailCache {
    static let shared = SpeciesThumbnailCache()
    private let loader: any SpeciesImageLoading
    private let cache = NSCache<NSString, UIImage>()

    init(loader: any SpeciesImageLoading = BundleSpeciesImageLoader.shared, countLimit: Int = 400) {
        self.loader = loader
        cache.countLimit = countLimit
    }

    func thumbnail(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID, maxPixelSize: Int) async -> UIImage? {
        let key = "\(packID.rawValue)/\(image.fileName)@\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? await loader.imageData(for: image, packID: packID),
              let decoded = Self.downsample(data, maxPixelSize: maxPixelSize) else { return nil }
        cache.setObject(decoded, forKey: key)
        return decoded
    }

    static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,  // decode now, off the main thread
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
