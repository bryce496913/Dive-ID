import Foundation
import UIKit
import XCTest
@testable import DiveID

actor SpyMarineLifeIdentificationService: MarineLifeIdentificationService {
    private(set) var requests: [IdentificationRequest] = []
    private(set) var photos: [ProcessedPhoto?] = []
    var results: [IdentificationMatch]
    var error: (any Error)?

    init(results: [IdentificationMatch] = []) { self.results = results }

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        requests.append(request)
        photos.append(processedPhoto)
        if let error { throw error }
        return results
    }

    func callCount() -> Int { requests.count }
    func receivedRequests() -> [IdentificationRequest] { requests }
    func receivedPhotos() -> [ProcessedPhoto?] { photos }
    func setError(_ value: (any Error)?) { error = value }
    func setResults(_ value: [IdentificationMatch]) { results = value }
}

struct StubPhotoProcessingService: PhotoProcessingService {
    let photo: ProcessedPhoto
    func processPhotoData(_ data: Data) async throws -> ProcessedPhoto { photo }
}

final class DiveIDTests: XCTestCase {
    @MainActor
    func testDescriptionCreatesSessionWithoutCallingServiceAndPreservesText() async throws {
        let store = InMemoryIdentificationSessionStore()
        let viewModel = DescriptionSearchViewModel(sessionStore: store)
        viewModel.descriptionText = "  Blue fish, with spots!  "
        let submittedSessionID = await viewModel.submit()
        let sessionID = try XCTUnwrap(submittedSessionID)
        let request = try await store.request(for: sessionID)
        guard case .description(let description) = request.source else { return XCTFail("Expected description") }
        XCTAssertEqual(description, "Blue fish, with spots!")
    }

    @MainActor
    func testDescriptionRejectsWhitespace() {
        let viewModel = DescriptionSearchViewModel(sessionStore: InMemoryIdentificationSessionStore())
        viewModel.descriptionText = "  \n"
        XCTAssertFalse(viewModel.canSubmit)
    }

    @MainActor
    func testResultsExecuteExactlyOnceAndReuseSessionResult() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("yellow fish"))
        _ = try await store.createSession(for: request, photo: nil)
        let match = makeMatch(score: 0.9)
        let service = SpyMarineLifeIdentificationService(results: [match])
        let first = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await first.loadIfNeeded()
        await first.loadIfNeeded()
        let reopened = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await reopened.loadIfNeeded()
        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testPhotoBytesReachService() async throws {
        let store = InMemoryIdentificationSessionStore()
        let bytes = Data([2, 3, 4, 5])
        let photo = ProcessedPhoto(id: UUID(), previewData: Data([9]), uploadData: bytes, pixelWidth: 10, pixelHeight: 8, format: .jpeg)
        let request = IdentificationRequest(source: .processedPhoto(photo.reference))
        _ = try await store.createSession(for: request, photo: photo)
        let service = SpyMarineLifeIdentificationService(results: [makeMatch(score: 0.8)])
        let viewModel = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await viewModel.loadIfNeeded()
        let receivedPhoto = await service.receivedPhotos().first ?? nil
        XCTAssertEqual(receivedPhoto?.uploadData, bytes)
        XCTAssertNotEqual(bytes, Data([1]))
    }

    @MainActor
    func testRetryAddsOneCallAndClearsFailure() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("ray"))
        _ = try await store.createSession(for: request, photo: nil)
        let service = SpyMarineLifeIdentificationService()
        await service.setError(MockServiceError.demonstrationFailure)
        let viewModel = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await viewModel.loadIfNeeded()
        await service.setError(nil)
        await service.setResults([makeMatch(score: 0.7)])
        await viewModel.retry()
        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 2)
        guard case .loaded = viewModel.state else { return XCTFail("Expected loaded state") }
    }

    @MainActor
    func testNewerPhotoSelectionWinsAndClearsError() async throws {
        let second = ProcessedPhoto(id: UUID(), previewData: Data([2]), uploadData: Data([22]), pixelWidth: 2, pixelHeight: 2, format: .jpeg)
        let viewModel = PhotoIdentificationViewModel(
            sessionStore: InMemoryIdentificationSessionStore(),
            photoProcessor: StubPhotoProcessingService(photo: second)
        )
        viewModel.selectionError = .unableToRead
        viewModel.selectPhoto { Data([22]) }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(viewModel.processedPhoto, second)
        XCTAssertNil(viewModel.selectionError)
        XCTAssertFalse(viewModel.isLoadingSelection)
    }

    func testScoreBandBoundariesAndRelativeMockSemantics() async throws {
        XCTAssertEqual(MatchStrength.band(for: 0.85), .strong)
        XCTAssertEqual(MatchStrength.band(for: 0.65), .good)
        XCTAssertEqual(MatchStrength.band(for: 0.40), .possible)
        XCTAssertEqual(MatchStrength.band(for: 0.399), .weak)
        let request = IdentificationRequest(source: .description("fish"))
        let values = try await MockMarineLifeIdentificationService(delay: .zero).identify(request: request, processedPhoto: nil)
        XCTAssertTrue(values.allSatisfy { $0.scoreKind == .relativeMatch })
    }

    @MainActor
    func testResultsAreSortedLimitedAndEmptyIsNotFailure() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("fish"))
        _ = try await store.createSession(for: request, photo: nil)
        let scores = stride(from: 0.1, through: 1.2, by: 0.1).map { makeMatch(score: $0) }
        let service = SpyMarineLifeIdentificationService(results: scores)
        let viewModel = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await viewModel.loadIfNeeded()
        guard case .loaded(let matches) = viewModel.state else { return XCTFail("Expected matches") }
        XCTAssertEqual(matches.count, 10)
        XCTAssertEqual(matches.map(\.score), matches.map(\.score).sorted(by: >))

        let emptyRequest = IdentificationRequest(source: .description("none"))
        _ = try await store.createSession(for: emptyRequest, photo: nil)
        let emptyViewModel = IdentificationResultsViewModel(
            sessionID: emptyRequest.id,
            service: SpyMarineLifeIdentificationService(),
            sessionStore: store
        )
        await emptyViewModel.loadIfNeeded()
        guard case .empty = emptyViewModel.state else { return XCTFail("Expected empty state") }
    }

    func testPhotoProcessingBoundsOutputDimensions() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_500))
        let input = renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
        }
        let processed = try await DefaultPhotoProcessingService().processPhotoData(input)
        XCTAssertLessThanOrEqual(max(processed.pixelWidth, processed.pixelHeight), DefaultPhotoProcessingService.uploadMaximumDimension)
        XCTAssertNotNil(UIImage(data: processed.previewData))
        XCTAssertNotNil(UIImage(data: processed.uploadData))
    }

    func testJSONRepositoryPersistsDeduplicatesAndRemoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.json")
        let first = MockSpecies.all[0]
        let second = MockSpecies.all[1]
        let repository = try JSONSavedSpeciesRepository(fileURL: url)
        try await repository.save(first)
        try await repository.save(first)
        try await repository.save(second)
        let saved = try await repository.fetchSavedSpecies()
        XCTAssertEqual(saved.count, 2)
        let recreated = try JSONSavedSpeciesRepository(fileURL: url)
        let firstIsSaved = try await recreated.isSaved(first)
        XCTAssertTrue(firstIsSaved)
        try await recreated.remove(first)
        let final = try JSONSavedSpeciesRepository(fileURL: url)
        let remaining = try await final.fetchSavedSpecies()
        XCTAssertEqual(remaining, [second])
    }

    func testCorruptPersistenceIsReportedWithoutOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("saved.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        let repository = try JSONSavedSpeciesRepository(fileURL: url)
        do { try await repository.save(MockSpecies.all[0]); XCTFail("Expected corrupt data error") }
        catch { XCTAssertEqual(try Data(contentsOf: url), corrupt) }
    }

    private func makeMatch(score: Double) -> IdentificationMatch {
        IdentificationMatch(id: MockSpecies.all[0].id, species: MockSpecies.all[0], score: score, scoreKind: .relativeMatch)
    }
}
