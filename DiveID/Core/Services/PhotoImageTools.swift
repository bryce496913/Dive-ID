import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(CoreImage)
import CoreImage
#endif
#if canImport(Vision)
import Vision
#endif

/// The part of a photo to identify, as fractions of its width and height with the origin at
/// the top left. The full photo is (0, 0, 1, 1).
struct PhotoCropRegion: Hashable, Sendable {
    var x: Double, y: Double, width: Double, height: Double

    static let full = PhotoCropRegion(x: 0, y: 0, width: 1, height: 1)
    /// The smallest box the diver can drag to, per side.
    static let minimumSide = 0.1

    var isFull: Bool { self == .full }

    /// Inside the photo and at least `minimumSide` on each side.
    func clamped() -> PhotoCropRegion {
        let w = min(max(width, Self.minimumSide), 1), h = min(max(height, Self.minimumSide), 1)
        return PhotoCropRegion(x: min(max(x, 0), 1 - w), y: min(max(y, 0), 1 - h), width: w, height: h)
    }

    /// Larger on every side by `fraction` of its size, then clamped: a little context around the animal.
    func padded(by fraction: Double) -> PhotoCropRegion {
        PhotoCropRegion(x: x - width * fraction, y: y - height * fraction,
                        width: width * (1 + 2 * fraction), height: height * (1 + 2 * fraction)).clamped()
    }

    /// The share of the photo the box covers, for VoiceOver.
    var area: Double { width * height }
}

enum PhotoImageError: Error, Equatable { case unreadable, encodingFailed, unavailable }

/// Image steps before recognition. Every output is a newly encoded JPEG, so no metadata
/// (EXIF, GPS) is carried over; everything runs on the device.
enum PhotoImageTools {
    static let jpegQuality = 0.85

    /// The region of an encoded image, as a new JPEG, and its pixel size.
    static func crop(_ data: Data, to region: PhotoCropRegion) throws -> (data: Data, width: Int, height: Int) {
#if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PhotoImageError.unreadable }
        let r = region.clamped()
        let rect = CGRect(x: (r.x * Double(image.width)).rounded(), y: (r.y * Double(image.height)).rounded(),
                          width: max(1, (r.width * Double(image.width)).rounded()), height: max(1, (r.height * Double(image.height)).rounded()))
        guard let cropped = r.isFull ? image : image.cropping(to: rect) else { throw PhotoImageError.unreadable }
        return (try jpeg(cropped), cropped.width, cropped.height)
#else
        throw PhotoImageError.unavailable
#endif
    }

#if canImport(ImageIO)
    static func jpeg(_ image: CGImage, quality: Double = jpegQuality) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoImageError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoImageError.encodingFailed }
        return output as Data
    }
#endif

    /// A box around the most likely subject, padded a little, or nil when Vision finds none.
    /// Vision's animal detector knows only cats and dogs, so object saliency does the work for
    /// marine life; the diver can always adjust the box or use the whole photo.
    static func suggestedRegion(_ data: Data) -> PhotoCropRegion? {
#if canImport(Vision)
        let handler = VNImageRequestHandler(data: data, options: [:])
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
#if targetEnvironment(simulator)
        if let cpu = try? saliency.supportedComputeStageDevices[.main]?.first(where: { if case .cpu = $0 { return true } else { return false } }) {
            saliency.setComputeDevice(cpu, for: .main)
        }
#endif
        guard (try? handler.perform([saliency])) != nil,
              let objects = saliency.results?.first?.salientObjects,
              let best = objects.max(by: { $0.boundingBox.width * $0.boundingBox.height * Double($0.confidence)
                                          < $1.boundingBox.width * $1.boundingBox.height * Double($1.confidence) }) else { return nil }
        let box = best.boundingBox  // normalized, origin at the bottom left
        let region = PhotoCropRegion(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height).padded(by: 0.1)
        // Nearly the whole photo already: suggest the whole photo.
        return region.area > 0.9 ? nil : region
#else
        return nil
#endif
    }
}

/// Internal experiment: simple underwater colour correction before recognition. Grey-world
/// white balance (scale each channel so the photo's average is neutral), with the red gain
/// capped, which restores some of the red water absorbs. Off unless the toggle is on.
enum UnderwaterColourCorrection {
    /// UserDefaults key for the Debug and Internal toggle.
    static let settingKey = "DiveIDExperimentalColourCorrection"
    static let maximumGain = 3.0

    /// Per-channel gains (red, green, blue) that make the given average neutral.
    static func gains(averageRed r: Double, green g: Double, blue b: Double) -> (Double, Double, Double) {
        let mean = (r + g + b) / 3
        func gain(_ c: Double) -> Double { c > 0.001 ? min(max(mean / c, 1 / maximumGain), maximumGain) : 1 }
        return (gain(r), gain(g), gain(b))
    }

    /// The corrected photo as a new JPEG.
    static func apply(_ data: Data) throws -> Data {
#if canImport(CoreImage) && canImport(ImageIO)
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw PhotoImageError.unreadable }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
        guard let average = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)])?.outputImage
        else { throw PhotoImageError.unreadable }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let (r, g, b) = gains(averageRed: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
        guard let balanced = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
        ])?.outputImage, let output = context.createCGImage(balanced, from: image.extent) else { throw PhotoImageError.encodingFailed }
        return try PhotoImageTools.jpeg(output)
#else
        throw PhotoImageError.unavailable
#endif
    }
}

extension ProcessedPhoto {
    /// The same photo with the region the recognizer gets cropped, optionally colour corrected.
    /// The preview stays the full photo.
    func preparedForRecognition(region: PhotoCropRegion, colourCorrected: Bool = false) throws -> ProcessedPhoto {
        guard !region.isFull || colourCorrected else { return self }
        var (data, width, height) = region.isFull ? (uploadData, pixelWidth, pixelHeight) : try PhotoImageTools.crop(uploadData, to: region)
        if colourCorrected { data = try UnderwaterColourCorrection.apply(data) }
        return ProcessedPhoto(id: id, previewData: previewData, uploadData: data, pixelWidth: width, pixelHeight: height, format: .jpeg)
    }
}
