import XCTest
@testable import DiveID

final class DiveIDTests: XCTestCase {
    @MainActor func testDescriptionRejectsWhitespace() { XCTAssertFalse(DescriptionSearchViewModel(service: MockMarineLifeIdentificationService(delay: .zero)).canSubmit); let vm = DescriptionSearchViewModel(service: MockMarineLifeIdentificationService(delay: .zero)); vm.descriptionText = "  \n"; XCTAssertFalse(vm.canSubmit) }
    func testMockResultsAreLimitedSortedAndValid() async throws { let values = try await MockMarineLifeIdentificationService(delay: .zero).identify(from: "fish"); XCTAssertLessThanOrEqual(values.count, 10); XCTAssertEqual(values, values.sorted { $0.confidence > $1.confidence }); XCTAssertTrue(values.allSatisfy { (0...1).contains($0.confidence) }) }
    func testRepositorySaveDeduplicatesAndRemovesOnlyRequestedSpecies() async throws { let repo = InMemorySavedSpeciesRepository(); let first = MockSpecies.all[0], second = MockSpecies.all[1]; try await repo.save(first); try await repo.save(first); try await repo.save(second); let saved = try await repo.fetchSavedSpecies(); XCTAssertEqual(saved.count, 2); try await repo.remove(first); let remaining = try await repo.fetchSavedSpecies(); XCTAssertEqual(remaining, [second]) }
    @MainActor func testDetailSavedState() async throws { let repo = InMemorySavedSpeciesRepository(); let species = MockSpecies.all[0]; try await repo.save(species); let vm = SpeciesDetailViewModel(species: species, confidence: nil, repository: repo); await vm.load(); XCTAssertTrue(vm.isSaved) }
    @MainActor func testErrorsBecomeFriendlyState() async { let vm = IdentificationResultsViewModel(source: .description("fish"), service: MockMarineLifeIdentificationService(delay: .zero, shouldFail: true)); await vm.load(); guard case .failed(let message) = vm.state else { return XCTFail("Expected failure") }; XCTAssertFalse(message.isEmpty) }
}
