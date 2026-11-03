import XCTest
@testable import DiveID
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

/// Cropping, the suggested crop box and the colour-correction experiment, on generated images.
final class PhotoImageToolsTests: XCTestCase {
    func testRegionsAreClampedPaddedAndMeasured() {
        XCTAssertEqual(PhotoCropRegion(x: -0.2, y: 0.95, width: 0.5, height: 0.01).clamped(), PhotoCropRegion(x: 0, y: 0.9, width: 0.5, height: 0.1))
        XCTAssertEqual(PhotoCropRegion(x: 0.4, y: 0.4, width: 0.2, height: 0.2).padded(by: 0.25).width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(PhotoCropRegion(x: 0, y: 0, width: 2, height: 2).clamped(), .full)
        XCTAssertEqual(PhotoCropRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5).area, 0.25)
    }

    func testColourGainsNeutraliseABlueCastAndAreCapped() {
        let (r, g, b) = UnderwaterColourCorrection.gains(averageRed: 0.2, green: 0.5, blue: 0.8)
        XCTAssertEqual(r, 2.5, accuracy: 1e-9)
        XCTAssertEqual(g, 1.0, accuracy: 1e-9)
        XCTAssertEqual(b, 0.625, accuracy: 1e-9)
        XCTAssertEqual(UnderwaterColourCorrection.gains(averageRed: 0.05, green: 0.5, blue: 0.95).0, UnderwaterColourCorrection.maximumGain)
        XCTAssertEqual(UnderwaterColourCorrection.gains(averageRed: 0, green: 0.5, blue: 0.5).0, 1, "no red at all: left alone")
    }

#if canImport(ImageIO)
    /// A JPEG with a dark blue background and a bright orange rectangle, with EXIF and GPS.
    private func photo(width: Int = 400, height: Int = 300, object: CGRect? = CGRect(x: 240, y: 60, width: 100, height: 80),
                       background: (CGFloat, CGFloat, CGFloat) = (0.05, 0.2, 0.45)) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: background.0, green: background.1, blue: background.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let object {
            context.setFillColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
            // CGContext's origin is the bottom left; `object` is given from the top left.
            context.fill(CGRect(x: object.minX, y: CGFloat(height) - object.maxY, width: object.width, height: object.height))
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil))
        let metadata: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
                                         kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 25.0, kCGImagePropertyGPSLongitude: 80.0]]
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func averageColour(_ data: Data) throws -> (r: Double, g: Double, b: Double) {
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil)), 0, nil))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var sums = (0.0, 0.0, 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) { sums.0 += Double(pixels[i]); sums.1 += Double(pixels[i + 1]); sums.2 += Double(pixels[i + 2]) }
        let n = Double(image.width * image.height) * 255
        return (sums.0 / n, sums.1 / n, sums.2 / n)
    }

    func testCropKeepsTheRegionAndDropsMetadata() throws {
        let original = try photo()
        XCTAssertNotNil(try properties(original)[kCGImagePropertyGPSDictionary], "the fixture has GPS")
        let (data, width, height) = try PhotoImageTools.crop(original, to: PhotoCropRegion(x: 0.6, y: 0.2, width: 0.25, height: 0.2666667))
        XCTAssertEqual(width, 100)
        XCTAssertEqual(height, 80)
        let colour = try averageColour(data)
        XCTAssertGreaterThan(colour.r, 0.9, "the crop is the orange object")
        let metadata = try properties(data)
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary])
        XCTAssertNil((metadata[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
    }

    func testPreparedPhotoCropsTheUploadAndKeepsTheFullPreview() throws {
        let data = try photo()
        let processed = ProcessedPhoto(id: UUID(), previewData: data, uploadData: data, pixelWidth: 400, pixelHeight: 300, format: .jpeg)
        XCTAssertEqual(try processed.preparedForRecognition(region: .full), processed, "the whole photo is sent unchanged")
        let cropped = try processed.preparedForRecognition(region: PhotoCropRegion(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(cropped.id, processed.id)
        XCTAssertEqual(cropped.previewData, data)
        XCTAssertEqual((cropped.pixelWidth, cropped.pixelHeight).0, 200)
        XCTAssertEqual(cropped.pixelHeight, 150)
    }

    func testColourCorrectionRestoresRedInABlueCastPhoto() throws {
        let blue = try photo(object: nil, background: (0.1, 0.35, 0.6))
        let before = try averageColour(blue)
        let corrected = try UnderwaterColourCorrection.apply(blue)
        let after = try averageColour(corrected)
        XCTAssertGreaterThan(after.r, before.r * 2, "red restored")
        XCTAssertLessThan(abs(after.r - after.b), abs(before.r - before.b) / 2, "closer to neutral")
        XCTAssertNil(try properties(corrected)[kCGImagePropertyGPSDictionary])
        XCTAssertEqual(try UnderwaterColourCorrection.apply(blue), corrected, "deterministic")
    }

    func testSuggestedRegionFindsTheObject() throws {
        try XCTSkipUnless(VisionFeaturePrint.isAvailable, "needs Apple Vision")
        let region = try XCTUnwrap(PhotoImageTools.suggestedRegion(try photo()), "saliency finds the bright object")
        // The object spans x 0.6–0.85, y 0.2–0.47 of the photo; the box must contain its centre.
        XCTAssertTrue(region.x < 0.725 && region.x + region.width > 0.725 && region.y < 0.333 && region.y + region.height > 0.333, "\(region)")
        XCTAssertLessThan(region.area, 0.9)
    }
#endif
}
