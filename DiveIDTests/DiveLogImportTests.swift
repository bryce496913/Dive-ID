import XCTest
@testable import DiveID

/// Import Backup: whole-file checks, the preview plan, the conflict policy, atomic and
/// repeatable imports, and the screen model. Every test uses its own temporary file or
/// in-memory store.
@MainActor
final class DiveLogImportTests: XCTestCase {
    private let salt = Dive(date: LocalDate("2026-03-14")!, startTime: LocalTime("09:30"), siteName: "Salt Pier", regionID: .global,
                            maximumDepth: Depth(value: 18, unit: .metres), durationMinutes: 55, notes: "Calm",
                            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.123_456))
    private let klein = Dive(date: LocalDate("2026-03-15")!, siteName: "Klein Bonaire", maximumDepth: Depth(value: 60, unit: .feet),
                             createdAt: Date(timeIntervalSinceReferenceDate: 800_100_000.987_654))
    private let emptyDive = Dive(date: LocalDate("2026-03-16")!, siteName: "No sightings", createdAt: Date(timeIntervalSinceReferenceDate: 800_200_000))

    private func species(_ name: String) -> Species {
        var species = Species(id: UUID(), commonName: name, scientificName: "\(name) scientifica", summary: "", visualCharacteristics: [],
                              habitat: "", geographicRange: "", imageAssetName: nil)
        species.bundledImage = BundledSpeciesImage(fileName: "\(name.replacingOccurrences(of: " ", with: "-")).jpg", alternativeText: name,
                                                   creatorName: "A", sourceName: "S", sourceURL: "https://example.org", licenseName: "CC BY 4.0",
                                                   licenseURL: "https://creativecommons.org/licenses/by/4.0/")
        return species
    }

    /// A photo search: provenance, cautions and a matched reference, all to be preserved.
    private func photoSighting(_ name: String, diveID: UUID?, at time: TimeInterval, notes: String? = nil, depth: Depth? = nil) -> SavedIdentification {
        let species = species(name)
        var match = IdentificationMatch(id: species.id, species: species, rank: 2, score: 0.61, scoreKind: .relativeMatch, strength: .good,
                                        explanation: "Blue and yellow", cautions: ["Juveniles look different"])
        match.sourceSessionID = UUID()
        match.photoEvidence = PhotoMatchEvidence(referenceID: "bundled:\(name)", referenceFileName: "\(name)-ref.jpg")
        match.photoRecognizer = PhotoRecognizerInfo(recognizerID: "vision-featureprint", recognizerVersion: "1", isPlaceholder: false)
        var sighting = SavedIdentification(match: match, identifiedAt: Date(timeIntervalSinceReferenceDate: time + 0.000_321), notes: notes)
        sighting.diveID = diveID
        sighting.depth = depth
        return sighting
    }

    /// A populated log: two dives with sightings, a dive with none, two separate sightings of
    /// one species on different dives, a field-guide bookmark and an unassigned search save.
    private func populatedLog() -> (dives: [Dive], sightings: [SavedIdentification]) {
        let turtle = species("Green Turtle")
        var first = SavedIdentification(fieldGuideSpecies: turtle, identifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_100.5), separateSighting: true)
        first.diveID = salt.id; first.notes = "Morning"; first.depth = Depth(value: 0, unit: .metres)
        var second = SavedIdentification(fieldGuideSpecies: turtle, identifiedAt: Date(timeIntervalSinceReferenceDate: 800_100_100.25), separateSighting: true)
        second.diveID = klein.id; second.notes = "Afternoon"
        let bookmark = SavedIdentification(fieldGuideSpecies: species("Queen Angelfish"), identifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_200))
        return ([salt, klein, emptyDive], [
            photoSighting("Spotted Eagle Ray", diveID: salt.id, at: 800_000_300, notes: "Over sand, \"pair\"", depth: Depth(value: 12.5, unit: .metres)),
            first, second, bookmark,
            photoSighting("Barracuda", diveID: nil, at: 800_000_400),
        ])
    }

    private func backup(dives: [Dive], sightings: [SavedIdentification]) throws -> Data {
        let store = SavedStore(identifications: sightings, dives: dives)
        // As the Dive Log exports: dives newest first, unassigned sightings newest first.
        return try DiveLogExport.wholeLog(store.divesWithSightings(), unassigned: store.sortedIdentifications.filter { $0.diveID == nil },
                                          now: Date(timeIntervalSince1970: 1_800_000_000)).json()
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("saved-identifications.json")
    }

    private func edited(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func assertProblem(_ data: Data, contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try DiveLogBackup.read(data)
            XCTFail("expected a problem containing \(text)", file: file, line: line)
        } catch let problem as DiveLogBackup.Problem {
            XCTAssertTrue(problem.message.contains(text), problem.message, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }

    // MARK: Round trip and relaunch

    func testRoundTripIntoAnEmptyStoreSurvivesRelaunch() async throws {
        let log = populatedLog()
        let data = try backup(dives: log.dives, sightings: log.sightings)
        let file = try temporaryFile()
        let repository = try JSONSavedIdentificationRepository(fileURL: file)
        let applied = try await repository.importBackup(try DiveLogBackup.read(data))
        XCTAssertEqual(applied.newDives.count, 3, "the dive with no sightings comes too")
        XCTAssertEqual(applied.newSightings.count, 5)
        XCTAssertTrue(applied.conflicts.isEmpty)

        let relaunched = try JSONSavedIdentificationRepository(fileURL: file)
        let dives = try await relaunched.dives()
        let sightings = try await relaunched.fetchAll()
        let restored = try backup(dives: dives.map(\.dive), sightings: sightings)
        XCTAssertEqual(try DiveLogExport.jsonDecoder.decode(DiveLogExport.Document.self, from: restored),
                       try DiveLogExport.jsonDecoder.decode(DiveLogExport.Document.self, from: data),
                       "exporting the restored log gives the same backup: snapshots, provenance, cautions, notes, depths, dates and dives")
        let ray = try XCTUnwrap(sightings.first { $0.species.commonName == "Spotted Eagle Ray" })
        XCTAssertEqual(ray.photoEvidence?.referenceFileName, "Spotted Eagle Ray-ref.jpg")
        XCTAssertEqual(ray.cautions, ["Juveniles look different"])
        XCTAssertEqual(ray.depth, Depth(value: 12.5, unit: .metres))
        let turtles = sightings.filter { $0.species.commonName == "Green Turtle" }
        XCTAssertEqual(Set(turtles.compactMap(\.diveID)), [salt.id, klein.id], "two sightings of one species stay separate, each on its dive")
        XCTAssertEqual(turtles.first { $0.notes == "Morning" }?.depth, Depth(value: 0, unit: .metres), "zero depth is kept, not dropped")
        XCTAssertEqual(dives.first { $0.dive.id == emptyDive.id }?.sightings.count, 0)
    }

    func testRepeatedImportAddsNothingAndLeavesTheFileUnchanged() async throws {
        let log = populatedLog()
        let document = try DiveLogBackup.read(try backup(dives: log.dives, sightings: log.sightings))
        let file = try temporaryFile()
        let repository = try JSONSavedIdentificationRepository(fileURL: file)
        _ = try await repository.importBackup(document)
        let afterFirst = try Data(contentsOf: file)
        let second = try await repository.importBackup(document)
        XCTAssertFalse(second.hasChanges)
        XCTAssertEqual(second.alreadyPresentDives, 3)
        XCTAssertEqual(second.alreadyPresentSightings, 5)
        XCTAssertTrue(second.conflicts.isEmpty, "records that went through an export still match (dates to the millisecond)")
        XCTAssertEqual(try Data(contentsOf: file), afterFirst)
    }

    func testRecordsInTheLogBeforeExportAreRecognisedAsAlreadyPresent() async throws {
        // The log that made the backup imports it again: full-precision dates still match.
        let log = populatedLog()
        let repository = InMemorySavedIdentificationRepository(initial: log.sightings, dives: log.dives)
        let plan = try await repository.importBackup(try DiveLogBackup.read(try backup(dives: log.dives, sightings: log.sightings)))
        XCTAssertFalse(plan.hasChanges)
        XCTAssertEqual(plan.alreadyPresent, 8)
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testADiveOnlyBackupImportsItsDives() async throws {
        let data = try backup(dives: [salt, emptyDive], sightings: [])
        let repository = InMemorySavedIdentificationRepository()
        let plan = try await repository.importBackup(try DiveLogBackup.read(data))
        XCTAssertEqual(plan.newDives.map(\.id), [emptyDive.id, salt.id], "in the backup's order, newest first")
        let dives = try await repository.dives()
        XCTAssertEqual(Set(dives.map(\.dive.id)), [salt.id, emptyDive.id])
    }

    // MARK: Populated store and conflicts

    func testImportIntoAPopulatedLogKeepsEverythingAlreadyThere() async throws {
        let mine = photoSighting("Nurse Shark", diveID: nil, at: 800_500_000, notes: "Mine")
        let myDive = Dive(date: LocalDate("2026-04-01")!, siteName: "My dive")
        let repository = InMemorySavedIdentificationRepository(initial: [mine], dives: [myDive])
        let log = populatedLog()
        let plan = try await repository.importBackup(try DiveLogBackup.read(try backup(dives: log.dives, sightings: log.sightings)))
        XCTAssertEqual([plan.newDives.count, plan.newSightings.count, plan.conflicts.count], [3, 5, 0])
        let all = await repository.fetchAll()
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.first { $0.id == mine.id }, mine, "the existing record is untouched")
        let dives = await repository.dives()
        XCTAssertTrue(dives.contains { $0.dive == myDive })
    }

    func testConflictingIDsKeepTheExistingRecordsAndNeverMisfileSightings() async throws {
        let log = populatedLog()
        var changedDive = salt
        changedDive.siteName = "Renamed after export"
        var changedSighting = log.sightings[4]  // the unassigned barracuda
        changedSighting.notes = "Edited after export"
        let repository = InMemorySavedIdentificationRepository(initial: [changedSighting], dives: [changedDive])
        let plan = try await repository.importBackup(try DiveLogBackup.read(try backup(dives: log.dives, sightings: log.sightings)))

        XCTAssertEqual(Set(plan.newDives.map(\.id)), [klein.id, emptyDive.id])
        let conflictIDs = Set(plan.conflicts.map(\.id))
        XCTAssertTrue(conflictIDs.contains(salt.id), "the changed dive is a conflict")
        XCTAssertTrue(conflictIDs.contains(changedSighting.id), "the changed sighting is a conflict")
        let saltSightings = log.sightings.filter { $0.diveID == salt.id }.map(\.id)
        XCTAssertTrue(Set(saltSightings).isSubset(of: conflictIDs), "sightings of a conflicting dive are not added to the existing dive")
        XCTAssertEqual(plan.conflicts.count, 2 + saltSightings.count)

        let dives = await repository.dives()
        XCTAssertEqual(dives.first { $0.dive.id == salt.id }?.dive.siteName, "Renamed after export")
        XCTAssertEqual(dives.first { $0.dive.id == salt.id }?.sightings, [], "nothing was filed under the conflicting dive")
        let all = await repository.fetchAll()
        XCTAssertEqual(all.first { $0.id == changedSighting.id }?.notes, "Edited after export")
    }

    func testDifferentIDsAreNeverMergedEvenWhenAlike() async throws {
        let original = photoSighting("Barracuda", diveID: nil, at: 800_000_400, notes: "Same notes")
        let lookalike = SavedIdentification(id: UUID(), match: original.match, identifiedAt: original.identifiedAt, notes: "Same notes")
        // Same species, time and notes but its own search: a separate record.
        var otherSearch = original.match
        otherSearch.sourceSessionID = UUID()
        let separate = SavedIdentification(match: otherSearch, identifiedAt: original.identifiedAt, notes: "Same notes")
        let repository = InMemorySavedIdentificationRepository(initial: [original])
        let plan = try await repository.importBackup(try DiveLogBackup.read(try backup(dives: [], sightings: [separate, lookalike])))
        XCTAssertEqual(plan.newSightings.map(\.id), [separate.id], "a different ID from another search is added, not merged")
        XCTAssertEqual(plan.conflicts.map(\.id), [lookalike.id], "the same search's save under another ID is reported, since the app keeps one per search")
        let all = await repository.fetchAll()
        XCTAssertEqual(all.count, 2)
    }

    func testASecondFieldGuideBookmarkForASpeciesIsReported() async throws {
        let angelfish = species("Queen Angelfish")
        let mine = SavedIdentification(fieldGuideSpecies: angelfish)
        let theirs = SavedIdentification(fieldGuideSpecies: angelfish)
        let logged = SavedIdentification(fieldGuideSpecies: angelfish, separateSighting: true)
        let repository = InMemorySavedIdentificationRepository(initial: [mine])
        let plan = try await repository.importBackup(try DiveLogBackup.read(try backup(dives: [], sightings: [theirs, logged])))
        XCTAssertEqual(plan.conflicts.map(\.id), [theirs.id])
        XCTAssertEqual(plan.newSightings.map(\.id), [logged.id], "a separately logged sighting of the species is still added")
    }

    func testThePlanIsMadeAgainWhenImportingSoAChangeSinceThePreviewIsRespected() async throws {
        let data = try backup(dives: [salt], sightings: [])
        let repository = InMemorySavedIdentificationRepository()
        let importer = DiveLogImportViewModel(repository: repository)
        await importer.prepare(data, fileName: "backup.json")
        XCTAssertEqual(importer.preview?.plan.newDives.count, 1)
        var meanwhile = salt
        meanwhile.notes = "Created elsewhere"
        _ = try await repository.createDive(meanwhile)
        await importer.confirm()
        let dives = await repository.dives()
        XCTAssertEqual(dives.map(\.dive.notes), ["Created elsewhere"], "no duplicate dive, and the existing one is kept")
        XCTAssertEqual(importer.result, "Imported 0 dives and 0 sightings. 1 conflict kept your existing records.")
    }

    // MARK: Files that can't be imported

    func testMalformedAndUnsupportedFilesAreRejectedWithReasons() throws {
        let valid = try backup(dives: [salt], sightings: [photoSighting("Barracuda", diveID: salt.id, at: 800_000_400)])
        XCTAssertNoThrow(try DiveLogBackup.read(valid))
        assertProblem(Data(), contains: "empty")
        assertProblem(Data("not json".utf8), contains: "isn't readable JSON")
        assertProblem(Data("[1, 2]".utf8), contains: "isn't readable JSON")
        assertProblem(Data("dive_id,dive_date\r\n".utf8), contains: "isn't readable JSON")
        assertProblem(try edited(valid) { $0["format"] = "diveid-diver-feedback" }, contains: "isn't a Dive ID dive log backup")
        assertProblem(try edited(valid) { $0["schemaVersion"] = 2 }, contains: "newer version of Dive ID (backup version 2)")
        assertProblem(try edited(valid) { $0["schemaVersion"] = 0 }, contains: "Backup version 0 isn't supported")
        assertProblem(try edited(valid) { $0.removeValue(forKey: "schemaVersion") }, contains: "no version number")
        assertProblem(try edited(valid) { $0.removeValue(forKey: "unassignedSightings") }, contains: "unassignedSightings is missing")
        assertProblem(try edited(valid) { object in
            var dives = object["dives"] as! [[String: Any]]
            var sightings = dives[0]["sightings"] as! [[String: Any]]
            sightings[0].removeValue(forKey: "identifiedAt")
            dives[0]["sightings"] = sightings
            object["dives"] = dives
        }, contains: "dives[0].sightings[0].identifiedAt is missing")
        assertProblem(try edited(valid) { object in
            var dives = object["dives"] as! [[String: Any]]
            var dive = dives[0]["dive"] as! [String: Any]
            dive["date"] = "2026-02-30"
            dives[0]["dive"] = dive
            object["dives"] = dives
        }, contains: "dives[0].dive.date is not valid")
        assertProblem(try edited(valid) { object in
            var dives = object["dives"] as! [[String: Any]]
            var dive = dives[0]["dive"] as! [String: Any]
            dive["id"] = "not-a-uuid"
            dives[0]["dive"] = dive
            object["dives"] = dives
        }, contains: "dives[0].dive.id")
        assertProblem(try edited(valid) { $0["exportedAt"] = "yesterday" }, contains: "exportedAt is not valid")
    }

    func testBrokenStructureIsRejectedBeforeAnythingIsWritten() throws {
        let ray = photoSighting("Spotted Eagle Ray", diveID: salt.id, at: 800_000_300)
        func document(_ dives: [DiveLogExport.Document.DiveEntry], _ unassigned: [SavedIdentification] = []) -> Data {
            try! DiveLogExport.jsonEncoder().encode(DiveLogExport.Document(schemaVersion: 1, format: "diveid-dive-log", exportedAt: Date(),
                                                                       dives: dives, unassignedSightings: unassigned))
        }
        assertProblem(document([.init(dive: salt, sightings: []), .init(dive: salt, sightings: [])]), contains: "appears twice")
        assertProblem(document([.init(dive: salt, sightings: [ray])], [ray]), contains: "appears twice")
        assertProblem(document([.init(dive: klein, sightings: [ray])]), contains: "names a dive that isn't in the backup")
        assertProblem(document([.init(dive: salt, sightings: []), .init(dive: klein, sightings: [ray])]), contains: "listed under one dive but names another")
        assertProblem(document([.init(dive: salt, sightings: [])], [ray]), contains: "listed as on no dive but names a dive")
        var noDive = ray; noDive.diveID = nil
        assertProblem(document([.init(dive: salt, sightings: [noDive])]), contains: "listed under a dive but names no dive")
        assertProblem(document([], [ray]), contains: "names a dive that isn't in the backup")
        var deep = noDive; deep.depth = Depth(value: -3, unit: .metres)
        assertProblem(document([], [deep]), contains: "depth below zero")
        var badDive = salt; badDive.durationMinutes = 0
        assertProblem(document([.init(dive: badDive, sightings: [])]), contains: "Duration must be more than zero minutes.")
        var badPicture = noDive; badPicture.photoEvidence = PhotoMatchEvidence(referenceID: "x", referenceFileName: "../../secret.jpg")
        assertProblem(document([], [badPicture]), contains: "invalid file name")
        var noReference = noDive; noReference.photoEvidence = PhotoMatchEvidence(referenceID: "", referenceFileName: nil)
        assertProblem(document([], [noReference]), contains: "has no reference")
        XCTAssertThrowsError(try DiveLogBackup.checkSize(DiveLogBackup.maximumFileBytes + 1)) { error in
            XCTAssertTrue((error as? DiveLogBackup.Problem)?.message.contains("backups up to 50 MB") == true)
        }
    }

    // MARK: Failures, cancellation and the screen model

    func testAFailedWriteImportsNothingAndRetryWorks() async throws {
        let file = try temporaryFile()
        let mine = photoSighting("Nurse Shark", diveID: nil, at: 800_500_000)
        _ = try await JSONSavedIdentificationRepository(fileURL: file).save(mine)
        let before = try Data(contentsOf: file)
        let failing = FailureSwitch(isOn: true)
        let repository = PersistentSavedIdentificationRepository {
            try JSONSavedIdentificationRepository(fileURL: file, writeData: { data, url in
                if failing.isOn { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
        }
        var reloaded = 0
        let importer = DiveLogImportViewModel(repository: repository, onImported: { reloaded += 1 })
        let log = populatedLog()
        await importer.prepare(try backup(dives: log.dives, sightings: log.sightings), fileName: "backup.json")
        XCTAssertEqual(importer.preview?.plan.newSightings.count, 5)

        await importer.confirm()
        XCTAssertNotNil(importer.preview, "the preview stays open to try again")
        XCTAssertTrue(importer.importError?.contains("Nothing was imported; your dive log is unchanged.") == true)
        XCTAssertNil(importer.result)
        XCTAssertEqual(reloaded, 0)
        XCTAssertEqual(try Data(contentsOf: file), before, "the file is exactly as it was")

        failing.isOn = false
        await importer.confirm()
        XCTAssertNil(importer.preview)
        XCTAssertEqual(importer.result, "Imported 3 dives and 5 sightings.")
        XCTAssertEqual(reloaded, 1, "the log refreshes after a successful import")
        let all = try await JSONSavedIdentificationRepository(fileURL: file).fetchAll()
        XCTAssertEqual(all.count, 6)
    }

    func testCancellingTheFilePickerOrThePreviewChangesNothing() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let importer = DiveLogImportViewModel(repository: repository)
        await importer.fileChosen(.failure(CocoaError(.userCancelled)))
        XCTAssertNil(importer.problem, "cancelling the picker is not an error")
        await importer.fileChosen(.success([]))
        XCTAssertNil(importer.preview)

        await importer.prepare(try backup(dives: [salt], sightings: []), fileName: "backup.json")
        XCTAssertNotNil(importer.preview)
        importer.cancel()
        XCTAssertNil(importer.preview)
        let dives = await repository.dives()
        XCTAssertTrue(dives.isEmpty, "nothing is written without Import")
    }

    func testAFileThatCantBeReadShowsTheProblemAndNoPreview() async throws {
        let importer = DiveLogImportViewModel(repository: InMemorySavedIdentificationRepository())
        await importer.prepare(Data("{\"format\":\"diveid-dive-log\",\"schemaVersion\":9}".utf8), fileName: "new.json")
        XCTAssertNil(importer.preview)
        XCTAssertTrue(importer.problem?.contains("Update Dive ID") == true)

        let url = try temporaryFile().deletingLastPathComponent().appendingPathComponent("missing.json")
        await importer.open(url)
        XCTAssertTrue(importer.problem?.contains("couldn't be read") == true)
    }

    func testOpeningAFileReadsAndPreviewsIt() async throws {
        let url = try temporaryFile().deletingLastPathComponent().appendingPathComponent("DiveID-dive-log.json")
        let log = populatedLog()
        try backup(dives: log.dives, sightings: log.sightings).write(to: url)
        let importer = DiveLogImportViewModel(repository: InMemorySavedIdentificationRepository())
        await importer.open(url)
        let preview = try XCTUnwrap(importer.preview)
        XCTAssertEqual(preview.fileName, "DiveID-dive-log.json")
        XCTAssertEqual(preview.plan.newSightingsWithPictures, 5)
        XCTAssertEqual(preview.plan.newPhotoSearchSightings, 2)
    }

    func testTheDiveLogScreenRefreshesAfterAnImport() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let log = DiveLogViewModel(repository: repository)
        await log.load()
        XCTAssertTrue(log.isEmpty)
        let populated = populatedLog()
        await log.importer.prepare(try backup(dives: populated.dives, sightings: populated.sightings), fileName: "b.json")
        await log.importer.confirm()
        XCTAssertEqual(log.dives.count, 3)
        XCTAssertEqual(log.unassigned.count, 2, "the bookmark and the unassigned search save")
        XCTAssertEqual(log.sightingCount, 5)
    }
}

private final class FailureSwitch: @unchecked Sendable {
    var isOn: Bool
    init(isOn: Bool) { self.isOn = isOn }
}
