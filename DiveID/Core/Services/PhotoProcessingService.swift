import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoProcessingError: Error, Equatable {
    case unsupportedFormat
    case decodingFailed
    case encodingFailed
}

protocol PhotoProcessingService: Sendable {
    func processPhotoData(_ data: Data) async throws -> ProcessedPhoto
}

struct DefaultPhotoProcessingService: PhotoProcessingService {
    // Newly encoded JPEGs strip metadata and provide interoperable, bounded payloads.
    static let previewMaximumDimension = 1_200
    static let uploadMaximumDimension = 2_048
    static let jpegQuality = 0.8

    func processPhotoData(_ data: Data) async throws -> ProcessedPhoto {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let type = CGImageSourceGetType(source),
                  UTType(type as String)?.conforms(to: .image) == true else {
                throw PhotoProcessingError.unsupportedFormat
            }
            let upload = try Self.makeJPEG(source: source, maximumDimension: Self.uploadMaximumDimension, quality: Self.jpegQuality)
            try Task.checkCancellation()
            let preview = try Self.makeJPEG(source: source, maximumDimension: Self.previewMaximumDimension, quality: Self.jpegQuality)
            return ProcessedPhoto(
                id: UUID(),
                previewData: preview.data,
                uploadData: upload.data,
                pixelWidth: upload.width,
                pixelHeight: upload.height,
                format: .jpeg
            )
        }.value
    }

    private static func makeJPEG(source: CGImageSource, maximumDimension: Int, quality: Double) throws -> (data: Data, width: Int, height: Int) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoProcessingError.decodingFailed
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoProcessingError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoProcessingError.encodingFailed }
        return (output as Data, image.width, image.height)
    }
}
