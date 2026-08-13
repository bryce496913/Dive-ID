import XCTest
@testable import DiveID

struct IdentificationBenchmarkCase: Codable { let id: String; let split: String; let description: String; let selectedPackID: OfflineIdentificationPackID; let expectedSpeciesIDs: [UUID]; let acceptableSpeciesIDs: [UUID]; let informationLevel: ObservationInformationLevel; let expectedNoUsefulMatch: Bool; let notes: String? }

final class IdentificationBenchmarkTests: XCTestCase {
    private func fixture() throws -> [IdentificationBenchmarkCase] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/CaribbeanIdentificationBenchmark.json")
        return try JSONDecoder().decode([IdentificationBenchmarkCase].self, from: Data(contentsOf: url))
    }

    func testBenchmarkFixtureHasUniqueDescriptionsAndRequiredSplit() throws {
        let cases = try fixture()
        XCTAssertEqual(cases.count, 100)
        XCTAssertEqual(Set(cases.map(\.description)).count, cases.count)
        XCTAssertGreaterThanOrEqual(cases.filter { $0.split == "development" }.count, 70)
        XCTAssertGreaterThanOrEqual(cases.filter { $0.split == "holdout" }.count, 30)
    }

    func testBenchmarkActuallyRunsIdentification() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self))
        let service = LocalMarineLifeIdentificationService(catalogRepository: repository, parser: LocalObservationParser(), ranker: LocalSpeciesRanker())
        for item in try fixture() {
            let request = IdentificationRequest(source: .description(item.description), context: .init(region: item.selectedPackID))
            let matches = try await service.identify(request: request, processedPhoto: nil)
            let accepted = Set(item.expectedSpeciesIDs + item.acceptableSpeciesIDs)
            XCTAssertFalse(accepted.isDisjoint(with: Set(matches.prefix(3).map(\.species.id))), item.id)
        }
    }
}
