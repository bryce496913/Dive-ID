import XCTest
@testable import DiveID

/// Editing a saved sighting's notes, depth and dive: the stored change, relaunch, the editor
/// screen's rules (validation, Cancel, failures, a dive deleted mid-edit) and the export.
/// Every test uses its own temporary file or in-memory store.
@MainActor
final class SightingEditTests: XCTestCase {
    private let salt = Dive(date: LocalDate("2026-03-14")!, siteName: "Salt Pier", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
    private let klein = Dive(date: LocalDate("2026-03-15")!, siteName: "Klein Bonaire", createdAt: Date(timeIntervalSinceReferenceDate: 800_100_000))

    /// A photo-search sighting with every field an edit must leave alone.
    private func photoSighting(notes: String? = "First notes", depth: Depth? = Depth(value: 12, unit: .metres), diveID: UUID? = nil) -> SavedIdentification {
        let species = Species(id: UUID(), commonName: "Queen Angelfish", scientificName: "Holacanthus ciliaris", summary: "", visualCharacteristics: [],
                              habitat: "", geographicRange: "", imageAssetName: nil)
        var match = IdentificationMatch(id: species.id, species: species, rank: 2, score: 0.7, scoreKind: .relativeMatch, strength: .good,
                                        explanation: "Blue and yellow", cautions: ["Juveniles look different"])
        match.sourceSessionID = UUID()
        match.photoEvidence = PhotoMatchEvidence(referenceID: "bundled:angelfish", referenceFileName: "angelfish.jpg")
        match.photoRecognizer = PhotoRecognizerInfo(recognizerID: "vision-featureprint", recognizerVersion: "1", isPlaceholder: false)
        var sighting = SavedIdentification(match: match, identifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_500), notes: notes)
        sighting.depth = depth
        sighting.diveID = diveID
        return sighting
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("saved-identifications.json")
    }

    /// A file store holding the two dives and `sightings`.
    private func fileStore(_ sightings: [SavedIdentification], file: URL? = nil,
                           writeData: (@Sendable (Data, URL) throws -> Void)? = nil) async throws -> (JSONSavedIdentificationRepository, URL) {
        let url = try file ?? temporaryFile()
        let seed = try JSONSavedIdentificationRepository(fileURL: url)
        _ = try await seed.createDive(salt)
        _ = try await seed.createDive(klein)
        for sighting in sightings { _ = try await seed.save(sighting) }
        let repository = try writeData.map { try JSONSavedIdentificationRepository(fileURL: url, writeData: $0) } ?? JSONSavedIdentificationRepository(fileURL: url)
        return (repository, url)
    }

    // MARK: Stored change and relaunch

    func testNotesDepthAndDiveSurviveRelaunchAndNothingElseChanges() async throws {
        let original = photoSighting(diveID: salt.id)
        let (repository, file) = try await fileStore([original])
        let stored = try await repository.editSighting(id: original.id,
            SightingEdit(notes: "Pair under the pier", depth: Depth(value: 40, unit: .feet), diveID: klein.id))

        var expected = original
        expected.notes = "Pair under the pier"; expected.depth = Depth(value: 40, unit: .feet); expected.diveID = klein.id
        XCTAssertEqual(stored, expected, "only notes, depth and dive change: ID, species, time, photo references, provenance and cautions are kept")

        let relaunched = try JSONSavedIdentificationRepository(fileURL: file)  // a new instance reads the file again
        let all = try await relaunched.fetchAll()
        XCTAssertEqual(all, [expected], "one sighting: editing never adds or merges")
        let dives = try await relaunched.dives()
        XCTAssertEqual(dives.first { $0.dive.id == salt.id }?.sightings.count, 0)
        XCTAssertEqual(dives.first { $0.dive.id == klein.id }?.sightings.map(\.id), [original.id])
    }

    func testClearingDepthIsUnknownAndZeroIsARealDepth() async throws {
        let original = photoSighting()
        let (repository, file) = try await fileStore([original])
        _ = try await repository.editSighting(id: original.id, SightingEdit(notes: nil, depth: Depth(value: 0, unit: .metres), diveID: nil))
        var reopened = try await JSONSavedIdentificationRepository(fileURL: file).fetchAll()
        XCTAssertEqual(reopened.first?.depth, Depth(value: 0, unit: .metres), "zero is stored as zero")
        XCTAssertNil(reopened.first?.notes, "notes cleared")

        _ = try await repository.editSighting(id: original.id, SightingEdit(notes: nil, depth: nil, diveID: nil))
        reopened = try await JSONSavedIdentificationRepository(fileURL: file).fetchAll()
        XCTAssertNil(reopened.first?.depth, "cleared depth is unknown, not zero")
    }

    func testMovingToNoDiveMakesItUnassigned() async throws {
        let original = photoSighting(diveID: salt.id)
        let repository = InMemorySavedIdentificationRepository(initial: [original], dives: [salt, klein])
        let log = DiveLogViewModel(repository: repository)
        _ = try await repository.editSighting(id: original.id, SightingEdit(original).with(diveID: nil))
        await log.load()
        XCTAssertEqual(log.unassigned.map(\.id), [original.id])
        XCTAssertTrue(log.dives.allSatisfy { $0.sightings.isEmpty })
        XCTAssertEqual(log.sightingCount, 1)
    }

    func testRejectedEditsChangeNothingOnDisk() async throws {
        let original = photoSighting(diveID: salt.id)
        let (repository, file) = try await fileStore([original])
        let before = try Data(contentsOf: file)
        await assertThrows(.diveNotFound) { _ = try await repository.editSighting(id: original.id, SightingEdit(original).with(diveID: UUID())) }
        await assertThrows(.sightingNotFound) { _ = try await repository.editSighting(id: UUID(), SightingEdit(original)) }
        do {
            _ = try await repository.editSighting(id: original.id, SightingEdit(notes: nil, depth: Depth(value: -1, unit: .metres), diveID: nil))
            XCTFail("negative depth must be rejected")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), before, "a rejected edit writes nothing")
    }

    func testTwoSightingsOfOneSpeciesStayIndependent() async throws {
        let species = photoSighting().species
        let first = SavedIdentification(fieldGuideSpecies: species, identifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_000), separateSighting: true)
        let second = SavedIdentification(fieldGuideSpecies: species, identifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_900), separateSighting: true)
        let (repository, file) = try await fileStore([first, second])
        _ = try await repository.editSighting(id: first.id, SightingEdit(notes: "Morning", depth: Depth(value: 5, unit: .metres), diveID: salt.id))
        _ = try await repository.editSighting(id: second.id, SightingEdit(notes: "Afternoon", depth: nil, diveID: klein.id))
        let all = try await JSONSavedIdentificationRepository(fileURL: file).fetchAll()
        XCTAssertEqual(all.count, 2, "neither edit merged the two sightings")
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        XCTAssertEqual(byID[first.id]?.notes, "Morning")
        XCTAssertEqual(byID[first.id]?.diveID, salt.id)
        XCTAssertEqual(byID[second.id]?.notes, "Afternoon")
        XCTAssertEqual(byID[second.id]?.diveID, klein.id)
        XCTAssertNil(byID[second.id]?.depth)
    }

    // MARK: The editor screen

    func testTheFormShowsCurrentValuesAndExplainsBadDepthWithoutLosingEdits() {
        let original = photoSighting(depth: Depth(value: 40, unit: .feet), diveID: salt.id)
        let editor = SightingEditorViewModel(sighting: original, repository: InMemorySavedIdentificationRepository(), preferredUnit: .metres)
        XCTAssertEqual(editor.form.notes, "First notes")
        XCTAssertEqual(editor.form.depthText, "40")
        XCTAssertEqual(editor.form.depthUnit, .feet, "the stored units, not the setting")
        XCTAssertEqual(editor.form.diveID, salt.id)
        XCTAssertFalse(editor.hasChanges)

        editor.form.notes = "Changed"
        editor.form.depthText = "deep"
        XCTAssertEqual(editor.form.depthError, "Depth must be a number.")
        XCTAssertFalse(editor.canSave)
        editor.form.depthText = "5000"
        XCTAssertEqual(editor.form.depthError, "Depth must be between 0 and 1150 ft.")
        XCTAssertEqual(editor.form.notes, "Changed", "an invalid depth never discards other edits")
        XCTAssertTrue(editor.hasChanges)

        editor.form.depthText = "0"
        XCTAssertNil(editor.form.depthError, "zero (the surface) is allowed")
        XCTAssertEqual(editor.form.edit?.depth, Depth(value: 0, unit: .feet))
        editor.form.depthText = "  "
        XCTAssertNil(editor.form.edit?.depth, "blank is unknown")
        editor.form.depthUnit = .metres
        editor.form.depthText = "18,5"
        XCTAssertEqual(editor.form.edit?.depth, Depth(value: 18.5, unit: .metres))
        editor.form.notes = "   "
        XCTAssertNil(editor.form.edit?.notes, "blank notes are stored as none")

        let unknown = SightingEditorViewModel(sighting: photoSighting(depth: nil), repository: InMemorySavedIdentificationRepository(), preferredUnit: .feet)
        XCTAssertEqual(unknown.form.depthText, "")
        XCTAssertEqual(unknown.form.depthUnit, .feet, "no stored depth: the units setting")
    }

    func testSaveReassignsBetweenDivesAndRefreshesTheLog() async throws {
        let original = photoSighting(diveID: salt.id)
        let repository = InMemorySavedIdentificationRepository(initial: [original], dives: [salt, klein])
        let log = DiveLogViewModel(repository: repository)
        await log.load()
        XCTAssertEqual(log.dive(salt.id)?.sightings.count, 1)

        let detail = SpeciesDetailViewModel(saved: original, repository: repository)
        await detail.load()
        XCTAssertTrue(detail.canEditSighting)
        XCTAssertEqual(detail.sightingDive?.id, salt.id)
        let editor = try XCTUnwrap(detail.makeSightingEditor(preferredUnit: .metres))
        await editor.loadDives()
        XCTAssertEqual(Set(editor.dives.map(\.id)), [salt.id, klein.id])
        editor.form.diveID = klein.id
        editor.form.notes = "Moved"
        let stored = try await XCTUnwrapAsync(await editor.save())
        await detail.sightingEdited(stored)
        await log.load()  // what the page's onSightingChanged does

        XCTAssertEqual(detail.sighting?.notes, "Moved")
        XCTAssertEqual(detail.sightingDive?.id, klein.id)
        XCTAssertEqual(log.dive(salt.id)?.sightings.count, 0)
        XCTAssertEqual(log.dive(klein.id)?.sightings.map(\.id), [original.id])
        XCTAssertEqual(log.sightingCount, 1)
        XCTAssertNil(editor.errorMessage)
    }

    func testCancelLeavesStorageUnchanged() async throws {
        let original = photoSighting(diveID: salt.id)
        let repository = InMemorySavedIdentificationRepository(initial: [original], dives: [salt, klein])
        let editor = SightingEditorViewModel(sighting: original, repository: repository, preferredUnit: .metres)
        editor.form.notes = "Not saved"
        editor.form.depthText = ""
        editor.form.diveID = nil
        // Cancel dismisses the sheet without calling save().
        let all = await repository.fetchAll()
        XCTAssertEqual(all, [original])
    }

    func testAFailedSaveKeepsTheEditsAndRetrySucceeds() async throws {
        let original = photoSighting(diveID: salt.id)
        let failing = FailureSwitch(isOn: true)
        let (repository, file) = try await fileStore([original], writeData: { data, url in
            if failing.isOn { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let before = try Data(contentsOf: file)
        let editor = SightingEditorViewModel(sighting: original, repository: repository, preferredUnit: .metres)
        editor.form.notes = "Kept after failure"
        editor.form.depthText = "7"
        editor.form.diveID = klein.id
        let failed = await editor.save()
        XCTAssertNil(failed)
        XCTAssertTrue(editor.errorMessage?.contains("Your changes weren't saved.") == true)
        XCTAssertTrue(editor.errorMessage?.contains("Check available device storage") == true)
        XCTAssertEqual(editor.form.notes, "Kept after failure")
        XCTAssertEqual(editor.form.depthText, "7")
        XCTAssertEqual(editor.form.diveID, klein.id)
        XCTAssertEqual(try Data(contentsOf: file), before, "nothing was written")

        failing.isOn = false
        let stored = try await XCTUnwrapAsync(await editor.save())
        XCTAssertEqual(stored.notes, "Kept after failure")
        XCTAssertNil(editor.errorMessage)
    }

    func testADiveDeletedWhileEditingKeepsTheSightingAndTheOtherEdits() async throws {
        let original = photoSighting(diveID: salt.id)
        let repository = InMemorySavedIdentificationRepository(initial: [original], dives: [salt, klein])
        let editor = SightingEditorViewModel(sighting: original, repository: repository, preferredUnit: .metres)
        await editor.loadDives()
        editor.form.diveID = klein.id
        editor.form.notes = "Edited while the dive vanished"
        try await repository.deleteDive(id: klein.id)  // e.g. deleted on another screen

        let failed = await editor.save()
        XCTAssertNil(failed)
        XCTAssertTrue(editor.errorMessage?.contains("no longer exists") == true)
        XCTAssertNil(editor.form.diveID, "the missing dive is no longer chosen")
        XCTAssertEqual(editor.dives.map(\.id), [salt.id], "the list shows the dives that remain")
        XCTAssertEqual(editor.form.notes, "Edited while the dive vanished")
        let afterFailure = await repository.fetchAll()
        XCTAssertEqual(afterFailure, [original], "the sighting is kept, unchanged")

        let stored = try await XCTUnwrapAsync(await editor.save())
        XCTAssertNil(stored.diveID)
        XCTAssertEqual(stored.notes, "Edited while the dive vanished")
    }

    func testTheSightingsOwnDiveDeletedDuringEditingIsHandledToo() async throws {
        let original = photoSighting(diveID: salt.id)
        let repository = InMemorySavedIdentificationRepository(initial: [original], dives: [salt, klein])
        let editor = SightingEditorViewModel(sighting: original, repository: repository, preferredUnit: .metres)
        editor.form.notes = "Only notes changed"
        try await repository.deleteDive(id: salt.id)  // keeps its sightings unassigned
        let failed = await editor.save()
        XCTAssertNil(failed)
        XCTAssertNil(editor.form.diveID)
        let stored = try await XCTUnwrapAsync(await editor.save())
        XCTAssertEqual(stored.notes, "Only notes changed")
        XCTAssertNil(stored.diveID)
    }

    func testAPageNotOpenedFromTheDiveLogOffersNoSightingEdit() async {
        let original = photoSighting()
        let detail = SpeciesDetailViewModel(species: original.species, match: nil, repository: InMemorySavedIdentificationRepository())
        XCTAssertFalse(detail.canEditSighting)
        XCTAssertNil(detail.makeSightingEditor())
    }

    // MARK: Export

    func testExportsCarryTheEditedFieldsAndTheNewDive() async throws {
        let original = photoSighting(diveID: salt.id)
        let repository = InMemorySavedIdentificationRepository(initial: [original], dives: [salt, klein])
        _ = try await repository.editSighting(id: original.id,
            SightingEdit(notes: "Under the pier, \"pair\"", depth: Depth(value: 0, unit: .metres), diveID: klein.id))
        let log = DiveLogViewModel(repository: repository)
        await log.load()
        let export = DiveLogExport.wholeLog(log.dives, unassigned: log.unassigned, now: Date(timeIntervalSince1970: 1_800_000_000))

        let rows = DiveLogScreenTests.parseCSV(export.csv())
        let header = rows[0]
        let row = try XCTUnwrap(rows.dropFirst().first { $0.count == header.count })
        func value(_ column: String) -> String { row[header.firstIndex(of: column)!] }
        XCTAssertEqual(rows.count - 1, 1, "one row: the sighting was moved, not copied")
        XCTAssertEqual(value("dive_id"), klein.id.uuidString)
        XCTAssertEqual(value("dive_site"), "Klein Bonaire")
        XCTAssertEqual(value("sighting_id"), original.id.uuidString)
        XCTAssertEqual(value("sighting_depth"), "0")
        XCTAssertEqual(value("sighting_depth_unit"), "metres")
        XCTAssertEqual(value("sighting_notes"), "Under the pier, \"pair\"")
        XCTAssertEqual(value("photo_reference"), "angelfish.jpg")

        let document = try DiveLogExport.jsonDecoder.decode(DiveLogExport.Document.self, from: export.json())
        XCTAssertEqual(document.dives.first { $0.dive.id == salt.id }?.sightings, [])
        let moved = try XCTUnwrap(document.dives.first { $0.dive.id == klein.id }?.sightings.first)
        XCTAssertEqual(moved.diveID, klein.id)
        XCTAssertEqual(moved.depth, Depth(value: 0, unit: .metres))
        XCTAssertEqual(moved.photoEvidence, original.photoEvidence)
        XCTAssertTrue(document.unassignedSightings.isEmpty)
    }

    // MARK: Helpers

    private func assertThrows(_ expected: SavedIdentificationRepositoryError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SavedIdentificationRepositoryError, expected, file: file, line: line)
        }
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

private extension SightingEdit {
    func with(diveID: UUID?) -> SightingEdit { SightingEdit(notes: notes, depth: depth, diveID: diveID) }
}

private final class FailureSwitch: @unchecked Sendable {
    var isOn: Bool
    init(isOn: Bool) { self.isOn = isOn }
}
