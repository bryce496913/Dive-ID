import XCTest
@testable import DiveID

final class OfflineIdentificationPackTests: XCTestCase {
    func testCaribbeanFixtureCounts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/../../DiveID/Resources/IdentificationPacks/Caribbean").standardizedFileURL
        let manifest = try JSONDecoder().decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: root.appendingPathComponent("PackManifest.json")))
        XCTAssertEqual(manifest.id, .caribbean)
        XCTAssertEqual(manifest.speciesCount, 78)
        let profiles = try JSONDecoder().decode([LocalSpeciesProfile].self, from: Data(contentsOf: root.appendingPathComponent("Species.json")))
        XCTAssertEqual(profiles.count, 78)
        XCTAssertEqual(Set(profiles.map(\.id)).count, 78)
        XCTAssertEqual(Set(profiles.map(\.scientificName)).count, 78)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Images"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "svg" }.count, 78)
    }
}
