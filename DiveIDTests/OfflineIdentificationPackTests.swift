import XCTest
@testable import DiveID

final class OfflineIdentificationPackTests: XCTestCase {
    func testCaribbeanFixtureCounts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/../../DiveID/Resources/IdentificationPacks/Caribbean").standardizedFileURL
        let manifest = try JSONDecoder().decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: root.appendingPathComponent("PackManifest.json")))
        XCTAssertEqual(manifest.id, .caribbean)

        let profiles = try JSONDecoder().decode([LocalSpeciesProfile].self, from: Data(contentsOf: root.appendingPathComponent("Species.json")))
        XCTAssertEqual(profiles.count, manifest.speciesCount)
        XCTAssertEqual(Set(profiles.map(\.id)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map(\.scientificName)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map(\.commonName)).count, profiles.count)

        let imageDirectory = root.appendingPathComponent(manifest.imageSubdirectory)
        let bundledImageNames = Set(profiles.compactMap { $0.bundledImage?.fileName })
        XCTAssertEqual(bundledImageNames.count, profiles.count)
        for imageName in bundledImageNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: imageDirectory.appendingPathComponent(imageName).path), "Missing bundled image: \(imageName)")
        }
        let speciesImageNames = Set(try FileManager.default.contentsOfDirectory(at: imageDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svg" }
            .map(\.lastPathComponent))
        XCTAssertEqual(speciesImageNames, bundledImageNames)

        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(
            pack: OfflineIdentificationPack(metadata: manifest, profiles: profiles)
        ))
    }
}
