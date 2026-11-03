import XCTest
@testable import DiveID
@testable import PhotoIndexBuilder

/// The build-time index tool, with a fake feature printer (these run on Linux too).
final class PhotoIndexBuilderTests: XCTestCase {
    private var directory: URL!
    private let policy = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../SpeciesPhotos/photo_policy.json").standardized
    private let ray = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let eel = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Images"), withIntermediateDirectories: true)
        try Data(#"{"speciesResourceName": "Creatures", "imageSubdirectory": "Images"}"#.utf8)
            .write(to: directory.appendingPathComponent("PackManifest.json"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func writePack(_ records: [(UUID, String?, String)], photos: [String]) throws {
        let json = records.map { id, file, licence in
            file.map { #"{"id": "\#(id.uuidString)", "bundledImage": {"fileName": "\#($0)", "licenseName": "\#(licence)"}}"# }
                ?? #"{"id": "\#(id.uuidString)"}"#
        }
        try Data(("[" + json.joined(separator: ",") + "]").utf8).write(to: directory.appendingPathComponent("Creatures.json"))
        for photo in photos { try Data(photo.utf8).write(to: directory.appendingPathComponent("Images/\(photo)")) }
    }

    /// A fake print from the file's bytes: deterministic and different per file.
    private func builder() throws -> PhotoIndexBuilder {
        try PhotoIndexBuilder(packDirectory: directory, packID: "global", policyURL: policy) { url in
            let bytes = Array(try Data(contentsOf: url))
            return (0..<8).map { Float(bytes[$0 % bytes.count]) + Float($0) }
        }
    }

    func testBuildsAnIndexAndSidecarThatRoundTrip() throws {
        try writePack([(ray, "ray.jpg", "CC BY-NC 4.0"), (eel, "eel.jpg", "CC0 1.0"), (UUID(), nil, "")], photos: ["ray.jpg", "eel.jpg"])
        let (index, sidecar) = try builder().build()
        XCTAssertEqual(index.entries.map(\.speciesID), [ray, eel], "sorted by species ID; species without a photo are skipped")
        XCTAssertEqual(index.requestRevision, VisionFeaturePrint.requestRevision)
        let speciesData = try Data(contentsOf: directory.appendingPathComponent("Creatures.json"))
        XCTAssertEqual(index.catalogueContentVersion, PhotoReferenceIndex.catalogueContentVersion(packID: "global", speciesData: speciesData))
        XCTAssertEqual(sidecar.count, 2)
        XCTAssertEqual(sidecar.entries.map(\.licence), ["CC BY-NC 4.0", "CC0 1.0"])
        XCTAssertEqual(sidecar.entries[0].sha256, PhotoReferenceIndex.sha256Hex(Data("ray.jpg".utf8)))
        XCTAssertEqual(sidecar.indexSHA256, PhotoReferenceIndex.sha256Hex(index.encoded()))

        try PhotoIndexBuilder.write(index, sidecar, index: directory.appendingPathComponent("PhotoIndex.bin"),
                                    sidecar: directory.appendingPathComponent("PhotoIndex.json"))
        let decoded = try PhotoReferenceIndex.decode(Data(contentsOf: directory.appendingPathComponent("PhotoIndex.bin")))
        XCTAssertEqual(decoded, index)
        let sidecarData = try Data(contentsOf: directory.appendingPathComponent("PhotoIndex.json"))
        XCTAssertEqual(try JSONDecoder().decode(PhotoIndexBuilder.Sidecar.self, from: sidecarData), sidecar)
    }

    func testFailsWhenAnApprovedPhotoIsMissing() throws {
        try writePack([(ray, "ray.jpg", "CC BY 4.0"), (eel, "eel.jpg", "CC BY 4.0")], photos: ["ray.jpg"])
        XCTAssertThrowsError(try builder().build()) { error in
            let problems = (error as? PhotoIndexBuilder.Failure)?.problems ?? []
            XCTAssertEqual(problems.count, 1)
            XCTAssertTrue(problems[0].contains("eel.jpg is missing"), "\(problems)")
        }
    }

    func testFailsOnALicenceThePolicyDoesNotAllow() throws {
        for licence in ["CC BY-SA 4.0", "CC BY-ND 4.0", "All rights reserved", ""] {
            try writePack([(ray, "ray.jpg", licence)], photos: ["ray.jpg"])
            XCTAssertThrowsError(try builder().build(), licence) { error in
                XCTAssertTrue("\(error)".contains("not allowed by photo_policy.json"), "\(error)")
            }
        }
    }

    func testDecodeRejectsDamagedOrForeignFiles() throws {
        let index = try PhotoReferenceIndex(requestRevision: 2, catalogueContentVersion: "global-0", dimension: 2,
                                            entries: [.init(speciesID: ray, fileName: "a.jpg")], vectors: [[1, 0]])
        var data = index.encoded()
        XCTAssertEqual(try PhotoReferenceIndex.decode(data), index)
        XCTAssertThrowsError(try PhotoReferenceIndex.decode(data.dropLast(3)))
        XCTAssertThrowsError(try PhotoReferenceIndex.decode(Data("not an index".utf8)))
        data[4] = 9  // format version
        XCTAssertThrowsError(try PhotoReferenceIndex.decode(data)) { XCTAssertEqual($0 as? PhotoIndexError, .unsupportedFormat(9)) }
    }

    func testSearchTakesTheBestReferencePerSpeciesThenRanksSpecies() throws {
        let index = try PhotoReferenceIndex(
            requestRevision: 2, catalogueContentVersion: "global-0", dimension: 3,
            entries: [.init(speciesID: ray, fileName: "ray-1.jpg"), .init(speciesID: ray, fileName: "ray-2.jpg"), .init(speciesID: eel, fileName: "eel.jpg")],
            vectors: [[0, 1, 0], [1, 0.1, 0], [0.8, 0.6, 0]])
        let matches = index.nearestSpecies(to: [1, 0, 0], limit: 10)
        XCTAssertEqual(matches.map(\.speciesID), [ray, eel], "one result per species")
        XCTAssertEqual(matches[0].fileName, "ray-2.jpg", "the species' best reference")
        XCTAssertEqual(matches[0].cosine, Float(1 / (1 + 0.01).squareRoot()), accuracy: 1e-5)
        XCTAssertEqual(matches[1].cosine, 0.8, accuracy: 1e-5)
        XCTAssertEqual(index.nearestSpecies(to: [1, 0, 0], limit: 1).map(\.speciesID), [ray])
        XCTAssertTrue(index.nearestSpecies(to: [1, 0], limit: 5).isEmpty, "wrong dimension")
    }
}
