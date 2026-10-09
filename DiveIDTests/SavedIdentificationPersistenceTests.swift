import Foundation
import XCTest
@testable import DiveID

@MainActor
final class SavedIdentificationPersistenceTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sample() throws -> SavedIdentification {
        let url = try TestResources.fixture(named: "CurrentSchema", subdirectory: "SavedIdentifications")
        return try XCTUnwrap(JSONDecoder().decode(SavedIdentificationFile.self, from: Data(contentsOf: url)).identifications.first)
    }

    func testInitializationFailureIsVisibleAndRetrySavesDurably() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let file = blocked.appendingPathComponent("saved.json")
        let repository = PersistentSavedIdentificationRepository {
            try JSONSavedIdentificationRepository(fileURL: file)
        }
        let item = try sample()
        let detail = SpeciesDetailViewModel(species: item.species, match: item.match, repository: repository)
        let list = SavedSpeciesViewModel(repository: repository)
        await list.load()
        XCTAssertNotNil(list.errorMessage)
        XCTAssertFalse(list.isLoading)
        await detail.toggleSaved()
        XCTAssertFalse(detail.isSaved)
        XCTAssertNil(detail.savedIdentificationID)
        XCTAssertTrue(detail.errorMessage?.contains("Saved storage is unavailable") == true)
        // Simulate the storage obstruction being resolved outside the repository.
        try FileManager.default.removeItem(at: blocked)
        await detail.retry()
        XCTAssertTrue(detail.isSaved)
        XCTAssertNil(detail.errorMessage)
        await list.retry()
        XCTAssertNil(list.errorMessage)
        XCTAssertEqual(list.identifications.count, 1)
        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let restored = try await reopened.fetchAll()
        XCTAssertEqual(restored.first?.id, detail.savedIdentificationID)
        XCTAssertEqual(restored.first?.species.id, item.species.id)
    }

    func testWriteFailurePreservesDiskAndDetailState() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("saved.json")
        let item = try sample()
        let good = try JSONSavedIdentificationRepository(fileURL: file)
        _ = try await good.save(item)
        let original = try Data(contentsOf: file)
        let failing = try JSONSavedIdentificationRepository(fileURL: file, writeData: { _, _ in
            throw CocoaError(.fileWriteOutOfSpace)
        })
        let detail = SpeciesDetailViewModel(saved: item, repository: failing)
        await detail.toggleSaved()
        XCTAssertTrue(detail.isSaved)
        XCTAssertEqual(detail.savedIdentificationID, item.id)
        XCTAssertNotNil(detail.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), original)
        var another = item.match
        another.sourceSessionID = UUID()
        let unsaved = SpeciesDetailViewModel(species: item.species, match: another, repository: failing)
        await unsaved.toggleSaved()
        XCTAssertFalse(unsaved.isSaved)
        XCTAssertNil(unsaved.savedIdentificationID)
        XCTAssertNotNil(unsaved.errorMessage)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testWriteRetryCommitsToSameFileAndReopens() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("saved.json")
        let failureMarker = directory.appendingPathComponent("simulate-full-storage")
        try Data().write(to: failureMarker)
        let repository = try JSONSavedIdentificationRepository(fileURL: file, writeData: { data, url in
            if FileManager.default.fileExists(atPath: failureMarker.path) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        let item = try sample()
        let detail = SpeciesDetailViewModel(species: item.species, match: item.match, repository: repository)
        await detail.toggleSaved()
        XCTAssertFalse(detail.isSaved)
        XCTAssertNotNil(detail.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.removeItem(at: failureMarker)
        await detail.retry()
        XCTAssertTrue(detail.isSaved)
        XCTAssertNil(detail.errorMessage)
        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let records = try await reopened.fetchAll()
        XCTAssertEqual(records.map(\.id), [try XCTUnwrap(detail.savedIdentificationID)])
        XCTAssertEqual(records.first?.explanation, item.explanation)
    }

    func testListRemoveFailureRetainsRecordsAndRetryClearsError() async throws {
        let item = try sample()
        let repository = RecoverableSavedRepository(item: item)
        let list = SavedSpeciesViewModel(repository: repository)
        await list.load()
        await list.remove(item)
        XCTAssertEqual(list.identifications.map(\.id), [item.id])
        XCTAssertNotNil(list.errorMessage)
        await repository.recover()
        await list.retry()
        XCTAssertTrue(list.identifications.isEmpty)
        XCTAssertNil(list.errorMessage)
    }

    func testDetailRetriesFailedSaveAndRemoveWithoutOptimisticState() async throws {
        let item = try sample()
        let repository = RecoverableSavedRepository(item: item)
        let detail = SpeciesDetailViewModel(species: item.species, match: item.match, repository: repository)
        await detail.toggleSaved()
        XCTAssertFalse(detail.isSaved)
        XCTAssertNotNil(detail.errorMessage)
        await repository.recover()
        await detail.retry()
        XCTAssertTrue(detail.isSaved)
        XCTAssertNil(detail.errorMessage)
        let confirmedID = detail.savedIdentificationID
        await repository.failAgain()
        await detail.toggleSaved()
        XCTAssertTrue(detail.isSaved)
        XCTAssertEqual(detail.savedIdentificationID, confirmedID)
        XCTAssertNotNil(detail.errorMessage)
        await repository.recover()
        await detail.retry()
        XCTAssertFalse(detail.isSaved)
        XCTAssertNil(detail.savedIdentificationID)
        XCTAssertNil(detail.errorMessage)
    }

    func testFailedReloadRetainsConfirmedListAndRetryClearsError() async throws {
        let item = try sample()
        let repository = RecoverableSavedRepository(item: item)
        let list = SavedSpeciesViewModel(repository: repository)
        await list.load()
        await repository.failReads()
        await list.load()
        XCTAssertEqual(list.identifications.map(\.id), [item.id])
        XCTAssertNotNil(list.errorMessage)
        await repository.recover()
        await list.retry()
        XCTAssertEqual(list.identifications.map(\.id), [item.id])
        XCTAssertNil(list.errorMessage)
    }

    func testSaveAndRemoveSurviveNewRepositoryInstances() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("saved.json")
        let item = try sample()
        let first = try JSONSavedIdentificationRepository(fileURL: file)
        _ = try await first.save(item)
        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let records = try await reopened.fetchAll()
        XCTAssertEqual(records.map(\.id), [item.id])
        XCTAssertEqual(records.first?.observationDescription, item.observationDescription)
        XCTAssertEqual(records.first?.explanation, item.explanation)
        try await reopened.remove(id: item.id)
        let final = try JSONSavedIdentificationRepository(fileURL: file)
        let remaining = try await final.fetchAll()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUnreadableRecordsAreNeverReplacedBySaveOrRemove() async throws {
        for fixture in ["Corrupt", "FutureSchema"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("saved.json")
            let original = try Data(contentsOf: TestResources.fixture(named: fixture, subdirectory: "SavedIdentifications"))
            try original.write(to: file)
            let repository = try JSONSavedIdentificationRepository(fileURL: file)
            do { _ = try await repository.save(sample()); XCTFail("Save must fail") } catch { }
            do { try await repository.remove(id: UUID()); XCTFail("Remove must fail") } catch { }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
    }
}

private actor RecoverableSavedRepository: SavedIdentificationRepository {
    var item: SavedIdentification?
    var fails = true
    init(item: SavedIdentification) { self.item = item }
    var readsFail = false
    func recover() { fails = false; readsFail = false }
    func failAgain() { fails = true }
    func failReads() { readsFail = true }
    func fetchAll() throws -> [SavedIdentification] {
        if readsFail { throw CocoaError(.fileReadNoPermission) }
        return item.map { [$0] } ?? []
    }
    func save(_ value: SavedIdentification) throws -> SavedIdentification {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        item = value
        return value
    }
    func remove(id: UUID) throws {
        if fails { throw CocoaError(.fileWriteOutOfSpace) }
        item = nil
    }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) -> SavedIdentification? { item }
}
