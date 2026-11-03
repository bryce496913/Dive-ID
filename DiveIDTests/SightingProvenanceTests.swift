import XCTest
@testable import DiveID

/// Repeat field-guide sightings, photo provenance on saved sightings, and exporting a log of
/// dives alone.
@MainActor
final class SightingProvenanceTests: XCTestCase {
    private let species = Species(id: UUID(), commonName: "Queen Angelfish", scientificName: "Holacanthus ciliaris", summary: "",
                                  visualCharacteristics: [], habitat: "", geographicRange: "", imageAssetName: nil)

    private func day(_ number: Int) -> LocalDate { LocalDate(year: 2026, month: 11, day: number)! }

    // MARK: Log another sighting

    func testAFieldGuideSpeciesCanBeLoggedOnTwoDives() async throws {
        let monday = Dive(date: day(2)), tuesday = Dive(date: day(3))
        let repository = InMemorySavedIdentificationRepository(dives: [monday, tuesday])
        let page = SpeciesDetailViewModel(species: species, match: nil, repository: repository)
        await page.load()
        await page.toggleSaved()
        XCTAssertTrue(page.isSaved)
        let bookmark = try XCTUnwrap(page.savedIdentificationID)
        await page.addToDive(monday)

        XCTAssertTrue(page.canLogAnotherSighting)
        await page.logAnotherSighting(now: Date(timeIntervalSince1970: 1_800_000_000))
        let offer = try XCTUnwrap(page.addToDiveOffer, "the new sighting is offered Add to dive")
        XCTAssertNotEqual(offer.sightingID, bookmark)
        await page.addToDive(tuesday)

        var saved = try await repository.fetchAll()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.map(\.diveID)), [monday.id, tuesday.id], "one sighting on each dive")
        let separate = try XCTUnwrap(saved.first { $0.isSeparateSighting })
        XCTAssertEqual(separate.identifiedAt, Date(timeIntervalSince1970: 1_800_000_000), "its own time")
        XCTAssertTrue(separate.isFromFieldGuide)

        // Reopening the species still finds its bookmark; removing it leaves the other sighting and its dive.
        let again = SpeciesDetailViewModel(species: species, match: nil, repository: repository)
        await again.load()
        XCTAssertEqual(again.savedIdentificationID, bookmark)
        await again.toggleSaved()
        saved = try await repository.fetchAll()
        XCTAssertEqual(saved.map(\.id), [separate.id])
        XCTAssertEqual(saved.first?.diveID, tuesday.id)
    }

    func testBookmarksStillDeduplicateButSeparateSightingsNever() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let first = try await repository.save(SavedIdentification(fieldGuideSpecies: species))
        let duplicate = try await repository.save(SavedIdentification(fieldGuideSpecies: species))
        XCTAssertEqual(duplicate.id, first.id, "saving the bookmark twice keeps one")
        _ = try await repository.save(SavedIdentification(fieldGuideSpecies: species, separateSighting: true))
        _ = try await repository.save(SavedIdentification(fieldGuideSpecies: species, separateSighting: true))
        let count = try await repository.fetchAll().count
        XCTAssertEqual(count, 3)
    }

    func testOlderSavesDecodeAsBookmarks() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedIdentification(fieldGuideSpecies: species))) as? [String: Any])
        object.removeValue(forKey: "isSeparateSighting")
        object.removeValue(forKey: "photoRecognizer")
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SavedIdentification.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(decoded.isSeparateSighting)
        XCTAssertTrue(decoded.isFieldGuideBookmark)
        XCTAssertNil(decoded.photoRecognizer)
    }

    func testSearchResultsHaveNoLogAnotherSighting() {
        let match = IdentificationMatch(id: species.id, species: species, score: 0.6, scoreKind: .relativeMatch)
        XCTAssertFalse(SpeciesDetailViewModel(species: species, match: match, repository: InMemorySavedIdentificationRepository()).canLogAnotherSighting)
    }

    // MARK: Photo provenance

    private func photoMatch(placeholder: Bool) -> IdentificationMatch {
        var match = IdentificationMatch(id: species.id, species: species, score: 0.6, scoreKind: .relativeMatch, explanation: PhotoMatchingWeights.explanation)
        match.sourceSessionID = UUID()
        match.photoEvidence = PhotoMatchEvidence(referenceID: "bundled:x", referenceFileName: "x.jpg")
        match.photoRecognizer = PhotoRecognizerInfo(recognizerID: placeholder ? "stub" : "vision-featureprint", recognizerVersion: "1", isPlaceholder: placeholder)
        return match
    }

    func testSavedPhotoResultsKeepTheirRecognizerEvidenceAndPlaceholderStatus() throws {
        let saved = SavedIdentification(match: photoMatch(placeholder: true))
        XCTAssertTrue(saved.isFromPhoto)
        XCTAssertTrue(saved.isPlaceholderPhotoResult)
        XCTAssertEqual(saved.photoEvidence?.referenceFileName, "x.jpg")
        let decoded = try JSONDecoder().decode(SavedIdentification.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.photoRecognizer, saved.photoRecognizer, "survives the saved file")
        XCTAssertEqual(decoded.photoEvidence, saved.photoEvidence)
        let reopened = SpeciesDetailViewModel(saved: decoded, repository: InMemorySavedIdentificationRepository())
        XCTAssertEqual(reopened.match?.photoRecognizer?.isPlaceholder, true, "the reopened page can show the placeholder warning")
        XCTAssertEqual(reopened.match?.photoEvidence?.referenceFileName, "x.jpg")
    }

    func testExportsSayWhereEachSightingCameFrom() throws {
        let placeholder = SavedIdentification(match: photoMatch(placeholder: true))
        let real = SavedIdentification(match: photoMatch(placeholder: false))
        let search = SavedIdentification(match: IdentificationMatch(id: species.id, species: species, score: 0.6, scoreKind: .relativeMatch))
        let guide = SavedIdentification(fieldGuideSpecies: species)
        XCTAssertEqual([placeholder, real, search, guide].map(DiveLogExport.savedFrom), ["photoPlaceholder", "photo", "search", "fieldGuide"])
        let rows = DiveLogExport.wholeLog([], unassigned: [placeholder]).csv().components(separatedBy: "\r\n")
        let row = Dictionary(uniqueKeysWithValues: zip(DiveLogExport.columns, rows[1].components(separatedBy: ",")))
        XCTAssertEqual(row["photo_recognizer"], "stub 1")
        XCTAssertEqual(row["photo_reference"], "x.jpg")
        let json = String(decoding: try DiveLogExport.wholeLog([], unassigned: [placeholder]).json(), as: UTF8.self)
        XCTAssertTrue(json.contains("\"isPlaceholder\" : true"))
    }

    // MARK: Exporting dives alone

    func testALogOfDivesAloneCanBeExported() async throws {
        let dive = Dive(date: day(2), siteName: "Empty Reef", notes: "Nothing seen")
        let log = DiveLogViewModel(repository: InMemorySavedIdentificationRepository(dives: [dive]))
        await log.load()
        XCTAssertEqual(log.sightingCount, 0)
        XCTAssertTrue(log.canExport)
        let export = DiveLogExport.wholeLog(log.dives, unassigned: log.unassigned)
        XCTAssertEqual(export.rowCount, 0)
        let document = try DiveLogExport.jsonDecoder.decode(DiveLogExport.Document.self, from: export.json())
        XCTAssertEqual(document.dives.map(\.dive.siteName), ["Empty Reef"], "JSON keeps the empty dive")

        let empty = DiveLogViewModel(repository: InMemorySavedIdentificationRepository())
        await empty.load()
        XCTAssertFalse(empty.canExport)
    }
}
