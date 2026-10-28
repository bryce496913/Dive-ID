import Foundation
import XCTest
@testable import DiveID

/// Dives in the saved-identification file (schema 3): migration of every earlier fixture,
/// the current fixture, round trip, deleting a dive both ways, and storage failures.
final class DiveLogTests: XCTestCase {
    private let diveA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let diveB = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002")!
    private let diveC = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000003")!
    private let reefShark = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    private let eagleRay = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    // MARK: Migration of every existing fixture

    func testSchema1MigratesWithNoDivesAndIsRewrittenAsSchema3() async throws {
        let (repository, file) = try copy("Schema1")
        let saved = try await repository.fetchAll()
        XCTAssertEqual(saved.count, 1)
        XCTAssertNil(saved[0].diveID)
        XCTAssertNil(saved[0].depth)
        let dives = try await repository.dives()
        XCTAssertEqual(dives, [])
        let envelope = try JSONDecoder().decode(SavedIdentificationFile.self, from: Data(contentsOf: file))
        XCTAssertEqual(envelope.schemaVersion, 3, "schema 1 is still rewritten on first read")
    }

    func testSchema2FilesLoadWithNoDivesAndAreNotRewrittenUntilAChange() async throws {
        for (fixture, notes) in [("Schema2Historical", "Observed near the reef edge."), ("CurrentSchema", nil)] as [(String, String?)] {
            let (repository, file) = try copy(fixture)
            let original = try Data(contentsOf: file)
            let saved = try await repository.fetchAll()
            XCTAssertEqual(saved.count, 1, fixture)
            XCTAssertNil(saved[0].diveID, fixture)
            XCTAssertNil(saved[0].depth, fixture)
            XCTAssertEqual(saved[0].notes, notes, "\(fixture): diveNotes are the sighting's notes")
            let dives = try await repository.dives()
            XCTAssertEqual(dives, [], fixture)
            XCTAssertEqual(try Data(contentsOf: file), original, "\(fixture): reading never rewrites schema 2")

            _ = try await repository.createDive(Dive(date: try XCTUnwrap(LocalDate("2026-01-02"))))
            let envelope = try JSONDecoder().decode(SavedIdentificationFile.self, from: Data(contentsOf: file))
            XCTAssertEqual(envelope.schemaVersion, 3, "\(fixture): written as schema 3 on the next change")
            XCTAssertEqual(envelope.identifications.map(\.id), saved.map(\.id), "\(fixture): every sighting survives")
            XCTAssertEqual(envelope.identifications.first?.notes, saved.first?.notes)
        }
    }

    func testFutureAndCorruptFilesAreRejectedAndNeverOverwrittenByDiveChanges() async throws {
        for (fixture, expected) in [("FutureSchema", SavedIdentificationRepositoryError.unsupportedSchema), ("Corrupt", .corruptData)] {
            let (repository, file) = try copy(fixture)
            let original = try Data(contentsOf: file)
            await assertThrows(expected) { _ = try await repository.dives() }
            await assertThrows(expected) { _ = try await repository.createDive(Dive(date: LocalDate("2026-01-02")!)) }
            await assertThrows(expected) { try await repository.deleteDive(id: UUID()) }
            await assertThrows(expected) { try await repository.unassign(sightingIDs: []) }
            XCTAssertEqual(try Data(contentsOf: file), original, "\(fixture) is left exactly as it was")
        }
    }

    // MARK: Schema 3

    func testCurrentSchema3FixtureDecodesNewestFirstWithSightings() async throws {
        let (repository, _) = try copy("Schema3Current")
        let dives = try await repository.dives()
        XCTAssertEqual(dives.map(\.dive.id), [diveC, diveA, diveB], "date, then start time (none last), newest first")
        let a = try XCTUnwrap(dives.first { $0.dive.id == diveA })
        XCTAssertEqual(a.sightings.map(\.id), [reefShark])
        XCTAssertEqual(a.dive.startTime?.description, "09:30")
        XCTAssertEqual(a.dive.date.description, "2026-03-14")
        XCTAssertEqual(a.dive.siteName, "Salt Pier")
        XCTAssertEqual(a.dive.regionID, .tropicalAtlantic)
        XCTAssertEqual(a.dive.maximumDepth, Depth(value: 21.5, unit: .metres))
        XCTAssertEqual(a.dive.durationMinutes, 52)
        XCTAssertEqual(a.dive.waterTemperature, Temperature(value: 27, unit: .celsius))
        XCTAssertEqual(a.dive.visibility, Distance(value: 60, unit: .feet))
        XCTAssertEqual(a.dive.notes, "Strong current at the end")
        XCTAssertEqual(a.sightings.first?.depth, Depth(value: 18, unit: .metres))
        XCTAssertEqual(a.sightings.first?.notes, "Patrolling the edge of the wall")
        XCTAssertTrue(dives.first { $0.dive.id == diveC }?.sightings.isEmpty ?? false)
        let saved = try await repository.fetchAll()
        XCTAssertNil(saved.first { $0.id == eagleRay }?.diveID, "unassigned sightings stay in the saved list")
    }

    func testRoundTripThroughANewRepositoryInstance() async throws {
        let (repository, file) = try copy("Schema3Current")
        var dive = Dive(date: try XCTUnwrap(LocalDate("2026-04-01")), startTime: LocalTime("14:05"), siteName: "  Night dive  ",
                        maximumDepth: Depth(value: 30, unit: .feet), durationMinutes: 40, waterTemperature: Temperature(value: 80, unit: .fahrenheit))
        dive = try await repository.createDive(dive)
        try await repository.assign(sightingIDs: [eagleRay], toDive: dive.id)
        try await repository.updateSighting(id: eagleRay, depth: Depth(value: 9.5, unit: .metres), notes: "Over the sand")
        dive.notes = "Torch died at the end"
        let updated = try await repository.updateDive(dive)
        XCTAssertEqual(updated.createdAt, dive.createdAt, "creation time never changes")
        XCTAssertGreaterThanOrEqual(updated.updatedAt, dive.createdAt)

        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let dives = try await reopened.dives()
        let restored = try XCTUnwrap(dives.first { $0.dive.id == dive.id })
        XCTAssertEqual(restored.dive, updated)
        XCTAssertEqual(restored.dive.siteName, "  Night dive  ", "free text is kept as typed")
        XCTAssertEqual(restored.sightings.map(\.id), [eagleRay])
        XCTAssertEqual(restored.sightings.first?.depth, Depth(value: 9.5, unit: .metres))
        XCTAssertEqual(restored.sightings.first?.notes, "Over the sand")
        XCTAssertEqual(dives.first?.dive.id, dive.id, "the newest dive comes first")

        try await reopened.unassign(sightingIDs: [eagleRay])
        let unassigned = try await reopened.fetchAll()
        XCTAssertNil(unassigned.first { $0.id == eagleRay }?.diveID)
    }

    // MARK: Deleting a dive

    func testDeletingADiveKeepsItsSightingsUnassignedByDefault() async throws {
        let (repository, _) = try copy("Schema3Current")
        try await repository.deleteDive(id: diveA)
        let dives = try await repository.dives()
        XCTAssertFalse(dives.contains { $0.dive.id == diveA })
        let saved = try await repository.fetchAll()
        XCTAssertEqual(Set(saved.map(\.id)), [reefShark, eagleRay], "nothing is lost")
        XCTAssertNil(saved.first { $0.id == reefShark }?.diveID)
        XCTAssertEqual(saved.first { $0.id == reefShark }?.notes, "Patrolling the edge of the wall", "the sighting keeps its own notes")
    }

    func testDeletingADiveWithItsSightingsRemovesOnlyThatDivesSightings() async throws {
        let (repository, _) = try copy("Schema3Current")
        try await repository.deleteDive(id: diveA, sightings: .deleteSightings)
        let saved = try await repository.fetchAll()
        XCTAssertEqual(saved.map(\.id), [eagleRay])
        let dives = try await repository.dives()
        XCTAssertEqual(dives.map(\.dive.id), [diveC, diveB])
        await assertThrows(.diveNotFound) { try await repository.deleteDive(id: self.diveA) }
    }

    // MARK: Rejected changes write nothing

    func testRejectedChangesLeaveTheFileUntouched() async throws {
        let (repository, file) = try copy("Schema3Current")
        let original = try Data(contentsOf: file)
        await assertThrows(.diveNotFound) { try await repository.assign(sightingIDs: [self.eagleRay], toDive: UUID()) }
        await assertThrows(.sightingNotFound) { try await repository.assign(sightingIDs: [self.eagleRay, UUID()], toDive: self.diveC) }
        await assertThrows(.sightingNotFound) { try await repository.updateSighting(id: UUID(), depth: nil, notes: nil) }
        await assertThrows(.diveNotFound) { _ = try await repository.updateDive(Dive(date: LocalDate("2026-01-02")!)) }
        await assertThrows(.invalidDive("Maximum depth must be zero or more.")) {
            _ = try await repository.createDive(Dive(date: LocalDate("2026-01-02")!, maximumDepth: Depth(value: -3, unit: .metres)))
        }
        await assertThrows(.invalidDive("Duration must be more than zero minutes.")) {
            _ = try await repository.createDive(Dive(date: LocalDate("2026-01-02")!, durationMinutes: 0))
        }
        await assertThrows(.invalidDive("Depth must be zero or more.")) {
            try await repository.updateSighting(id: self.eagleRay, depth: Depth(value: .nan, unit: .feet), notes: nil)
        }
        await assertThrows(.invalidDive("This dive already exists.")) {
            _ = try await repository.createDive(Dive(id: self.diveA, date: LocalDate("2026-01-02")!))
        }
        XCTAssertEqual(try Data(contentsOf: file), original, "a partially valid assignment changes nothing")
    }

    func testLocalDatesAndTimesRejectImpossibleValues() throws {
        XCTAssertNil(LocalDate("2026-02-30"))
        XCTAssertNil(LocalDate("2026-3-14"))
        XCTAssertNil(LocalTime("24:00"))
        XCTAssertNil(LocalTime("9:30"))
        XCTAssertEqual(LocalDate("2024-02-29")?.description, "2024-02-29")
        let bad = Data(#"{"id":"AAAAAAAA-0000-0000-0000-000000000009","date":"2026-13-01","createdAt":0,"updatedAt":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Dive.self, from: bad))
    }

    func testSavingFromSearchIsUnchangedAndStartsWithNoDive() async throws {
        let (repository, _) = try copy("Schema3Current")
        let file = try TestResources.fixture(named: "CurrentSchema", subdirectory: "SavedIdentifications")
        var match = try XCTUnwrap(JSONDecoder().decode(SavedIdentificationFile.self, from: Data(contentsOf: file)).identifications.first).match
        match.sourceSessionID = UUID()
        let saved = try await repository.save(SavedIdentification(match: match))
        XCTAssertNil(saved.diveID)
        XCTAssertNil(saved.depth)
        XCTAssertEqual(saved.savedFrom, .search)
    }

    // MARK: Storage failures (same error and retry behaviour as saved identifications)

    func testAFailedWriteKeepsTheFileAndRetrySucceeds() async throws {
        let (_, file) = try copy("Schema3Current")
        let original = try Data(contentsOf: file)
        let full = FailureSwitch(isOn: true)
        let repository = try JSONSavedIdentificationRepository(fileURL: file, writeData: { data, url in
            if full.isOn { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        do { try await repository.deleteDive(id: diveA); XCTFail("the write must fail") } catch {
            XCTAssertTrue(SavedIdentificationRepositoryError.message(for: error).contains("Check available device storage"))
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        let before = try await repository.dives()
        XCTAssertTrue(before.contains { $0.dive.id == diveA }, "nothing changed in memory either")
        full.isOn = false
        try await repository.deleteDive(id: diveA)
        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let after = try await reopened.dives()
        XCTAssertFalse(after.contains { $0.dive.id == diveA })
    }

    func testStorageThatCannotOpenIsReportedAndRetried() async throws {
        let directory = try temporaryDirectory()
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let file = blocked.appendingPathComponent("saved.json")
        let repository = PersistentSavedIdentificationRepository { try JSONSavedIdentificationRepository(fileURL: file) }
        await assertThrows(.initializationFailed) { _ = try await repository.createDive(Dive(date: LocalDate("2026-01-02")!)) }
        try FileManager.default.removeItem(at: blocked)
        let dive = try await repository.createDive(Dive(date: try XCTUnwrap(LocalDate("2026-01-02"))))
        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let dives = try await reopened.dives()
        XCTAssertEqual(dives.map(\.dive.id), [dive.id], "retried persistent storage, never memory")
    }

    func testInMemoryStoreFollowsTheSameRules() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let dive = try await repository.createDive(Dive(date: try XCTUnwrap(LocalDate("2026-05-05"))))
        await assertThrows(.sightingNotFound) { try await repository.assign(sightingIDs: [UUID()], toDive: dive.id) }
        try await repository.deleteDive(id: dive.id)
        let dives = try await repository.dives()
        XCTAssertEqual(dives, [])
    }

    // MARK: Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func copy(_ fixture: String) throws -> (JSONSavedIdentificationRepository, URL) {
        let file = try temporaryDirectory().appendingPathComponent("saved-identifications.json")
        try FileManager.default.copyItem(at: TestResources.fixture(named: fixture, subdirectory: "SavedIdentifications"), to: file)
        return (try JSONSavedIdentificationRepository(fileURL: file), file)
    }

    private func assertThrows(_ expected: SavedIdentificationRepositoryError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: @escaping () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as SavedIdentificationRepositoryError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private final class FailureSwitch: @unchecked Sendable {
    var isOn: Bool
    init(isOn: Bool) { self.isOn = isOn }
}
