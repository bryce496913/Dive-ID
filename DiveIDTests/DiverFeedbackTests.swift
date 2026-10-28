import XCTest
@testable import DiveID

/// Diver feedback: records for every answer, first-search and re-search flags, consent,
/// the export file and storage failures. All text here is synthetic, never a diver's.
@MainActor
final class DiverFeedbackTests: XCTestCase {
    private var pack: OfflineIdentificationPackMetadata!

    override func setUp() async throws {
        let catalog = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication)
        let packs = try await catalog.availablePacks()
        pack = try XCTUnwrap(packs.first { $0.id == .global })
    }

    private func matches(_ count: Int) -> [IdentificationMatch] {
        (1...count).map { rank in
            let species = Species(id: UUID(), commonName: "Synthetic \(rank)", scientificName: "Synthetica \(rank)", summary: "", visualCharacteristics: [],
                                  habitat: "", geographicRange: "", imageAssetName: nil)
            return IdentificationMatch(id: species.id, species: species, rank: rank, score: 1.0 / Double(rank), scoreKind: .relativeMatch)
        }
    }

    private func service(_ repository: any DiverFeedbackRepository = InMemoryDiverFeedbackRepository(),
                         settings: InMemoryFeedbackSettings = InMemoryFeedbackSettings()) -> DiverFeedbackService {
        DiverFeedbackService(repository: repository, settings: settings, app: AppInfo(version: "0.5", build: "2", channel: "debug"))
    }

    // MARK: Records

    func testEveryAnswerTypeSavesItsRecordWithTheUneditedDescription() async throws {
        let raw = "  SYNTHETIC: flat ray, white spots,\nlong tail  "
        for answer in [FeedbackAnswer.claimed(speciesID: UUID()), .noneOfThese, .notSure] {
            let repository = InMemoryDiverFeedbackRepository()
            let feedback = service(repository)
            let session = UUID()
            let shown = matches(12)
            let attempt = feedback.beginAttempt(sessionID: session, rawDescription: raw, pack: pack, previous: nil)
            feedback.recordShown(sessionID: session, matches: shown)
            let prompt = FeedbackPromptViewModel(sessionID: session, service: feedback)
            XCTAssertNil(prompt.pendingAnswer, "nothing is preselected")
            XCTAssertNil(prompt.activeStep)
            prompt.choose(answer)
            XCTAssertEqual(prompt.activeStep, .consent, "consent comes before the first save")
            prompt.consentDraft = FeedbackConsent(forEvaluation: true, forPublication: false)
            await prompt.confirmConsent()
            XCTAssertEqual(prompt.activeStep, .details)
            prompt.details = FeedbackDetails(broadRegion: "Synthetic sea", depthText: "12,5", depthUnit: .feet, uncertainty: "  ", hasPhotoToSend: true)
            await prompt.save()
            XCTAssertEqual(prompt.savedAnswer, answer)
            XCTAssertNil(prompt.activeStep)

            let records = try await repository.fetchAll()
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(record.answer, answer.kind)
            XCTAssertEqual(record.claimedSpeciesID, answer.claimedSpeciesID)
            XCTAssertEqual(record.originalDescription, raw, "exactly as typed: untrimmed, unedited")
            XCTAssertEqual(record.attemptID, attempt.attemptID)
            XCTAssertEqual(record.shownResults.map(\.rank), Array(1...10), "top ten as shown")
            XCTAssertEqual(record.shownResults.first?.speciesID, shown.first?.species.id)
            XCTAssertEqual(record.packID, "global")
            XCTAssertEqual(record.catalogueVersion, pack.packVersion)
            XCTAssertEqual([record.appVersion, record.appBuild, record.buildChannel], ["0.5", "2", "debug"])
            XCTAssertEqual(record.participantCode, "DIVER-TEST0001")
            XCTAssertEqual(record.approximateDepth, ApproximateDepth(value: 12.5, unit: .feet))
            XCTAssertEqual(record.broadRegion, "Synthetic sea")
            XCTAssertNil(record.uncertainty, "blank optional text is not stored")
            XCTAssertTrue(record.hasPhotoToSend)
            XCTAssertTrue(record.consentForEvaluation)
            XCTAssertFalse(record.consentForPublication)
        }
    }

    func testFirstSearchPriorExposureAndEditedReSearchFlags() async throws {
        let settings = InMemoryFeedbackSettings()
        let feedback = service(settings: settings)
        let first = feedback.beginAttempt(sessionID: UUID(), rawDescription: "SYNTHETIC one", pack: pack, previous: nil)
        XCTAssertTrue(first.firstSearchOfInstall)
        XCTAssertNil(first.researchOfAttemptID)
        XCTAssertFalse(first.editedAfterSeeingResults)
        let same = feedback.beginAttempt(sessionID: UUID(), rawDescription: "SYNTHETIC one", pack: pack, previous: first)
        XCTAssertFalse(same.firstSearchOfInstall)
        XCTAssertEqual(same.researchOfAttemptID, first.attemptID, "a re-search links to the earlier attempt")
        XCTAssertFalse(same.editedAfterSeeingResults)
        let edited = feedback.beginAttempt(sessionID: UUID(), rawDescription: "SYNTHETIC one, blue", pack: pack, previous: same)
        XCTAssertEqual(edited.researchOfAttemptID, same.attemptID)
        XCTAssertTrue(edited.editedAfterSeeingResults)
        XCTAssertTrue(settings.hasSearchedBefore, "kept per install")

        settings.consentDecided = true
        let firstRecord = try XCTUnwrap(feedback.makeRecord(sessionID: first.sessionID, answer: .notSure, details: .init()))
        let laterRecord = try XCTUnwrap(feedback.makeRecord(sessionID: edited.sessionID, answer: .notSure, details: .init()))
        XCTAssertFalse(firstRecord.priorExposure)
        XCTAssertTrue(laterRecord.priorExposure, "true after the install's first search")
        XCTAssertNil(feedback.makeRecord(sessionID: UUID(), answer: .notSure, details: .init()), "no record without a recorded search")
    }

    func testConsentIsAskedOnceAndAnsweringAgainReplacesTheRecord() async throws {
        let repository = InMemoryDiverFeedbackRepository()
        let feedback = service(repository)
        let session = UUID()
        feedback.beginAttempt(sessionID: session, rawDescription: "SYNTHETIC", pack: pack, previous: nil)
        let prompt = FeedbackPromptViewModel(sessionID: session, service: feedback)
        prompt.choose(.notSure)
        await prompt.confirmConsent()  // declines both: still allowed to save
        await prompt.save()
        prompt.choose(.noneOfThese)
        XCTAssertEqual(prompt.activeStep, .details, "consent is not asked again")
        await prompt.save()
        let records = try await repository.fetchAll()
        XCTAssertEqual(records.map(\.answer), ["none"])
        XCTAssertFalse(records[0].consentForEvaluation)
    }

    // MARK: Consent and export

    func testExportIncludesOnlyEvaluationConsentedRecordsAndWithdrawalApplies() async throws {
        let consented = try record(answer: .notSure, consent: .init(forEvaluation: true, forPublication: true))
        let declined = try record(answer: .noneOfThese, consent: .init())
        let repository = InMemoryDiverFeedbackRepository(initial: [consented, declined])
        let settings = InMemoryFeedbackSettings(consentDecided: true, consent: .init(forEvaluation: true, forPublication: true))
        let feedback = service(repository, settings: settings)

        var export = try await feedback.makeExport()
        XCTAssertEqual(export.records.map(\.feedbackID), [consented.feedbackID])

        let sharing = FeedbackSharingViewModel(service: feedback)
        await sharing.load()
        XCTAssertEqual(sharing.savedCount, 2)
        XCTAssertEqual(sharing.shareableCount, 1)
        await sharing.updateConsent(FeedbackConsent(forEvaluation: false, forPublication: true))
        XCTAssertEqual(sharing.shareableCount, 0, "withdrawing evaluation consent applies to saved records")
        export = try await feedback.makeExport()
        XCTAssertTrue(export.records.isEmpty)
    }

    func testWithdrawalThatFailsToRewriteRecordsStillExportsNothing() async throws {
        let consented = try record(answer: .notSure, consent: .init(forEvaluation: true, forPublication: false))
        let repository = ConsentFailingRepository(records: [consented])
        let settings = InMemoryFeedbackSettings(consentDecided: true, consent: .init(forEvaluation: true, forPublication: false))
        let feedback = service(repository, settings: settings)
        let sharing = FeedbackSharingViewModel(service: feedback)
        await sharing.load()
        await sharing.updateConsent(FeedbackConsent(forEvaluation: false, forPublication: false))
        XCTAssertNotNil(sharing.errorMessage, "the failed rewrite is reported")
        let stored = try await repository.fetchAll()
        XCTAssertTrue(stored[0].consentForEvaluation, "the stored record still says consented")
        XCTAssertEqual(sharing.shareableCount, 0)
        let export = try await feedback.makeExport()
        XCTAssertTrue(export.records.isEmpty, "the current setting wins")
    }

    func testOnlyTheLatestSearchesStayInMemory() {
        let feedback = service()
        let sessions = (0...DiverFeedbackService.maximumAttempts).map { _ in UUID() }
        for session in sessions { feedback.beginAttempt(sessionID: session, rawDescription: "SYNTHETIC", pack: pack, previous: nil) }
        XCTAssertNil(feedback.attempt(for: sessions[0]), "the oldest search is dropped")
        XCTAssertNotNil(feedback.attempt(for: sessions[1]))
        XCTAssertNotNil(feedback.attempt(for: sessions.last!))
    }

    func testEachExportReplacesTheEarlierFile() throws {
        let feedback = service()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let directory = ExportFiles.directory(base: base)
        let first = try feedback.writeExport(DiverFeedbackExport(records: [], evaluationConsent: true, participantCode: "DIVER-OLD00001"), directory: directory)
        let second = try feedback.writeExport(DiverFeedbackExport(records: [], evaluationConsent: true, participantCode: "DIVER-NEW00001"), directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testExportFileRoundTripsWithTheDocumentedShape() async throws {
        let original = DiverFeedbackExport(records: [try record(answer: .claimed(speciesID: UUID()), consent: .init(forEvaluation: true, forPublication: false))],
                                           evaluationConsent: true, participantCode: "DIVER-TEST0001", now: Date(timeIntervalSince1970: 1_800_000_000))
        let feedback = service()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = try feedback.writeExport(original, directory: directory)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("DiveID-feedback-DIVER-TEST0001-"))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(try DiverFeedbackExport.decoder.decode(DiverFeedbackExport.self, from: data), original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "format", "exportedAt", "participantCode", "note", "records"])
        XCTAssertEqual(object["format"] as? String, "diveid-diver-feedback")
        let row = try XCTUnwrap((object["records"] as? [[String: Any]])?.first)
        for key in ["feedbackID", "attemptID", "createdAt", "appVersion", "appBuild", "buildChannel", "packID", "catalogueVersion",
                    "participantCode", "originalDescription", "firstSearchOfInstall", "editedAfterSeeingResults", "shownResults",
                    "answer", "claimedSpeciesID", "hasPhotoToSend", "consentForEvaluation", "consentForPublication", "priorExposure"] {
            XCTAssertNotNil(row[key], key)
        }
        for forbidden in ["latitude", "longitude", "location", "deviceID", "name", "email"] { XCTAssertNil(row[forbidden], forbidden) }
    }

    func testCurrentSchemaFixtureDecodesAndExportsOnlyItsConsentedRecord() async throws {
        let (repository, _) = try storeCopy("FeedbackCurrentSchema")
        let records = try await repository.fetchAll()
        XCTAssertEqual(records.count, 2)
        let consented = try XCTUnwrap(records.first { $0.consentForEvaluation })
        XCTAssertEqual(consented.originalDescription, "  SYNTHETIC TEST TEXT, not a diver account: flat ray with white spots.  ")
        let export = DiverFeedbackExport(records: records, evaluationConsent: true, participantCode: "DIVER-TEST0001")
        XCTAssertEqual(export.records.map(\.feedbackID), [consented.feedbackID])
        let withdrawn = DiverFeedbackExport(records: records, evaluationConsent: false, participantCode: "DIVER-TEST0001")
        XCTAssertTrue(withdrawn.records.isEmpty, "a record still marked consented is left out once the setting is off")
    }

    // MARK: Storage failures (same pattern as saved identifications)

    func testFutureAndCorruptFilesAreReportedNeverReset() async throws {
        for (fixture, expected) in [("FeedbackFutureSchema", DiverFeedbackRepositoryError.unsupportedSchema), ("FeedbackCorrupt", .corruptData)] {
            let (repository, file) = try storeCopy(fixture)
            let before = try Data(contentsOf: file)
            do { _ = try await repository.fetchAll(); XCTFail("\(fixture) should not load") } catch {
                XCTAssertEqual(DiverFeedbackRepositoryError.message(for: error), expected.errorDescription)
            }
            do { _ = try await repository.save(try record(answer: .notSure, consent: .init())); XCTFail("\(fixture) should not be overwritten") } catch {}
            XCTAssertEqual(try Data(contentsOf: file), before, "the file is left as it was")
        }
    }

    func testAFailedSaveShowsAnErrorAndRetrySaves() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("diver-feedback.json")
        let fail = FailureSwitch()
        let repository = try JSONDiverFeedbackRepository(fileURL: file, writeData: { data, url in
            if fail.isOn { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        let feedback = service(repository, settings: InMemoryFeedbackSettings(consentDecided: true))
        let session = UUID()
        feedback.beginAttempt(sessionID: session, rawDescription: "SYNTHETIC", pack: pack, previous: nil)
        let prompt = FeedbackPromptViewModel(sessionID: session, service: feedback)
        fail.isOn = true
        prompt.choose(.notSure)
        await prompt.save()
        XCTAssertNil(prompt.savedAnswer)
        XCTAssertEqual(prompt.activeStep, .details, "the sheet stays open with the diver's details")
        XCTAssertNotNil(prompt.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        fail.isOn = false
        await prompt.retry()
        XCTAssertEqual(prompt.savedAnswer, .notSure)
        XCTAssertNil(prompt.errorMessage)
        let reopened = try JSONDiverFeedbackRepository(fileURL: file)
        let saved = try await reopened.fetchAll()
        XCTAssertEqual(saved.map(\.answer), ["notSure"])
    }

    func testStorageThatCannotOpenReportsAndRetriesTheSameFactory() async throws {
        let attempts = FailureSwitch()
        let repository = PersistentDiverFeedbackRepository(makeRepository: {
            attempts.count += 1
            throw CocoaError(.fileWriteNoPermission)
        })
        do { _ = try await repository.fetchAll(); XCTFail() } catch {
            XCTAssertEqual(DiverFeedbackRepositoryError.message(for: error), DiverFeedbackRepositoryError.initializationFailed.errorDescription)
        }
        _ = try? await repository.fetchAll()
        XCTAssertEqual(attempts.count, 2, "retries persistent storage, never falls back to memory")
    }

    func testParticipantCodeIsRandomAndMadeOncePerInstall() {
        let defaults = UserDefaults(suiteName: "DiverFeedbackTests-\(UUID())")!
        let settings = UserDefaultsFeedbackSettings(defaults: defaults)
        let code = settings.participantCode
        XCTAssertTrue(code.hasPrefix("DIVER-"))
        XCTAssertEqual(code.count, 14)
        XCTAssertEqual(settings.participantCode, code)
        XCTAssertNotEqual(UserDefaultsFeedbackSettings.makeParticipantCode(), UserDefaultsFeedbackSettings.makeParticipantCode())
        XCTAssertFalse(settings.consentDecided)
        XCTAssertEqual(settings.consent, FeedbackConsent(), "both consents start off")
    }

    // MARK: Helpers

    /// Saves and reads, but rewriting records for a consent change always fails.
    private actor ConsentFailingRepository: DiverFeedbackRepository {
        struct Failure: Error {}
        private var records: [DiverFeedbackRecord]
        init(records: [DiverFeedbackRecord]) { self.records = records }
        func fetchAll() -> [DiverFeedbackRecord] { records }
        func save(_ record: DiverFeedbackRecord) -> DiverFeedbackRecord { records.append(record); return record }
        func applyConsent(_ consent: FeedbackConsent) throws { throw Failure() }
    }

    private func record(answer: FeedbackAnswer, consent: FeedbackConsent) throws -> DiverFeedbackRecord {
        let attempt = FeedbackSearchAttempt(attemptID: UUID(), sessionID: UUID(), originalDescription: "SYNTHETIC text", firstSearchOfInstall: true,
                                            researchOfAttemptID: nil, editedAfterSeeingResults: false, packID: "global", catalogueVersion: 25,
                                            shownResults: [FeedbackShownResult(rank: 1, speciesID: UUID())])
        return DiverFeedbackRecord(attempt: attempt, answer: answer, details: FeedbackDetails(), consent: consent,
                                   participantCode: "DIVER-TEST0001", app: AppInfo(version: "0.5", build: "2", channel: "debug"),
                                   now: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private func storeCopy(_ fixture: String) throws -> (JSONDiverFeedbackRepository, URL) {
        let source = try TestResources.fixture(named: fixture, subdirectory: "DiverFeedback")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("diver-feedback.json")
        try FileManager.default.copyItem(at: source, to: file)
        return (try JSONDiverFeedbackRepository(fileURL: file), file)
    }
}

private final class FailureSwitch: @unchecked Sendable {
    var isOn = false
    var count = 0
}
