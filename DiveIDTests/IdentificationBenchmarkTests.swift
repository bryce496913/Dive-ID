import XCTest
@testable import DiveID

struct IdentificationBenchmarkCase: Codable { let id: String; let split: String; let description: String; let selectedPackID: OfflineIdentificationPackID; let expectedSpeciesIDs: [UUID]; let acceptableSpeciesIDs: [UUID]; let informationLevel: ObservationInformationLevel; let expectedNoUsefulMatch: Bool; let notes: String? }

final class IdentificationBenchmarkTests: XCTestCase {
    func testBenchmarkFixtureHasRequiredSplit() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/CaribbeanIdentificationBenchmark.json")
        let cases = try JSONDecoder().decode([IdentificationBenchmarkCase].self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(cases.count, 100)
        XCTAssertGreaterThanOrEqual(cases.filter { $0.split == "development" }.count, 70)
        XCTAssertGreaterThanOrEqual(cases.filter { $0.split == "holdout" }.count, 30)
    }
}
