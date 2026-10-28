import Foundation
import Observation

/// Records each description search for feedback and saves the diver's answers on this
/// device. It only observes: nothing here reaches search, ranking or result order, and
/// no feedback is ever read back by a search. Nothing is sent anywhere.
@MainActor
final class DiverFeedbackService {
    let repository: any DiverFeedbackRepository
    let settings: any FeedbackSettings
    let app: AppInfo
    private var attempts: [UUID: FeedbackSearchAttempt] = [:]
    /// Session IDs oldest first, so only the latest `maximumAttempts` searches stay in memory.
    private var attemptOrder: [UUID] = []
    static let maximumAttempts = 20

    init(repository: any DiverFeedbackRepository, settings: any FeedbackSettings, app: AppInfo = .current) {
        self.repository = repository
        self.settings = settings
        self.app = app
    }

    /// Called once a search session exists. `previous` is this screen's earlier attempt,
    /// whose results the diver has seen, so this one is a re-search of it.
    @discardableResult
    func beginAttempt(sessionID: UUID, rawDescription: String, pack: OfflineIdentificationPackMetadata,
                      previous: FeedbackSearchAttempt?) -> FeedbackSearchAttempt {
        let first = !settings.hasSearchedBefore
        settings.hasSearchedBefore = true
        let attempt = FeedbackSearchAttempt(
            attemptID: UUID(), sessionID: sessionID, originalDescription: rawDescription,
            firstSearchOfInstall: first, researchOfAttemptID: previous?.attemptID,
            editedAfterSeeingResults: previous.map { $0.originalDescription != rawDescription } ?? false,
            packID: pack.id.rawValue, catalogueVersion: pack.packVersion)
        attempts[sessionID] = attempt
        attemptOrder.removeAll { $0 == sessionID }
        attemptOrder.append(sessionID)
        while attemptOrder.count > Self.maximumAttempts { attempts[attemptOrder.removeFirst()] = nil }
        return attempt
    }

    /// The results as displayed (top ten, rank order). Called by the results screen.
    func recordShown(sessionID: UUID, matches: [IdentificationMatch]) {
        guard var attempt = attempts[sessionID] else { return }
        attempt.shownResults = matches.prefix(10).map { FeedbackShownResult(rank: $0.rank, speciesID: $0.species.id) }
        attempts[sessionID] = attempt
    }

    func attempt(for sessionID: UUID) -> FeedbackSearchAttempt? { attempts[sessionID] }

    var needsConsent: Bool { !settings.consentDecided }
    var consent: FeedbackConsent { settings.consent }

    /// Stores the diver's choice and applies it to every saved record, so withdrawing
    /// evaluation consent also keeps older records out of an export.
    func setConsent(_ consent: FeedbackConsent) async throws {
        settings.consent = consent
        settings.consentDecided = true
        try await repository.applyConsent(consent)
    }

    func makeRecord(sessionID: UUID, answer: FeedbackAnswer, details: FeedbackDetails, now: Date = Date()) -> DiverFeedbackRecord? {
        guard let attempt = attempts[sessionID] else { return nil }
        return DiverFeedbackRecord(attempt: attempt, answer: answer, details: details, consent: settings.consent,
                                   participantCode: settings.participantCode, app: app, now: now)
    }

    func savedRecord(for sessionID: UUID) async throws -> DiverFeedbackRecord? {
        guard let attempt = attempts[sessionID] else { return nil }
        return try await repository.fetchAll().first { $0.attemptID == attempt.attemptID }
    }

    /// The export of every evaluation-consented record, and none while the current
    /// setting is off.
    func makeExport(now: Date = Date()) async throws -> DiverFeedbackExport {
        DiverFeedbackExport(records: try await repository.fetchAll(), evaluationConsent: settings.consent.forEvaluation,
                            participantCode: settings.participantCode, now: now)
    }

    /// Writes the export to a temporary file for the share sheet.
    func writeExport(_ export: DiverFeedbackExport, directory: URL = ExportFiles.directory()) throws -> URL {
        ExportFiles.removeAll(in: directory)
        let day = ISO8601DateFormatter.string(from: export.exportedAt, timeZone: .current, formatOptions: [.withFullDate])
        let url = directory.appendingPathComponent("DiveID-feedback-\(export.participantCode)-\(day).json")
        try export.encoded().write(to: url, options: .atomic)
        return url
    }
}

/// The "Was this right?" flow for one search: answer, consent (first time only), optional
/// details, save. Nothing is chosen for the diver.
@MainActor @Observable
final class FeedbackPromptViewModel {
    let sessionID: UUID
    private let service: DiverFeedbackService
    var pendingAnswer: FeedbackAnswer?
    var details = FeedbackDetails()
    var consentDraft = FeedbackConsent()
    /// One sheet whose content moves through the steps, so no sheet is presented while another closes.
    var activeStep: FeedbackStep?
    enum FeedbackStep: Hashable { case pickMatch, consent, details }
    private(set) var savedAnswer: FeedbackAnswer?
    private(set) var isSaving = false
    var errorMessage: String?
    private var retryAction: RetryAction?
    private enum RetryAction { case consent, save }

    init(sessionID: UUID, service: DiverFeedbackService) {
        self.sessionID = sessionID
        self.service = service
    }

    /// False when the screen was not reached from a search recorded this launch.
    var isAvailable: Bool { service.attempt(for: sessionID) != nil }
    var shownResults: [FeedbackShownResult] { service.attempt(for: sessionID)?.shownResults ?? [] }

    func load() async {
        guard let record = try? await service.savedRecord(for: sessionID) else { return }
        switch record.answer {
        case "claimedSpecies": savedAnswer = record.claimedSpeciesID.map { .claimed(speciesID: $0) }
        case "none": savedAnswer = .noneOfThese
        case "notSure": savedAnswer = .notSure
        default: savedAnswer = nil
        }
    }

    func recordShown(_ matches: [IdentificationMatch]) { service.recordShown(sessionID: sessionID, matches: matches) }

    /// "Yes — this one" first asks which match.
    func chooseYes() { errorMessage = nil; activeStep = .pickMatch }

    func choose(_ answer: FeedbackAnswer) {
        pendingAnswer = answer
        errorMessage = nil
        if service.needsConsent {
            consentDraft = FeedbackConsent()  // both off until the diver turns one on
            activeStep = .consent
        } else {
            activeStep = .details
        }
    }

    func confirmConsent() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await service.setConsent(consentDraft)
            activeStep = .details
            errorMessage = nil
        } catch {
            retryAction = .consent
            errorMessage = DiverFeedbackRepositoryError.message(for: error)
        }
    }

    func cancel() {
        pendingAnswer = nil
        activeStep = nil
        errorMessage = nil
    }

    func save() async {
        guard let answer = pendingAnswer, let record = service.makeRecord(sessionID: sessionID, answer: answer, details: details) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await service.repository.save(record)
            savedAnswer = answer
            pendingAnswer = nil
            activeStep = nil
            details = FeedbackDetails()
            errorMessage = nil
        } catch {
            retryAction = .save
            errorMessage = DiverFeedbackRepositoryError.message(for: error)
        }
    }

    func retry() async {
        switch retryAction {
        case .consent: await confirmConsent()
        case .save: await save()
        case nil: break
        }
    }
}

/// Credits' "Your search feedback": consent, a count, and Share my feedback.
@MainActor @Observable
final class FeedbackSharingViewModel {
    private let service: DiverFeedbackService
    var consent: FeedbackConsent
    private(set) var records: [DiverFeedbackRecord] = []
    private(set) var export: DiverFeedbackExport?
    private(set) var exportURL: URL?
    var errorMessage: String?

    init(service: DiverFeedbackService) {
        self.service = service
        consent = service.consent
    }

    var participantCode: String { service.settings.participantCode }
    var savedCount: Int { records.count }
    var shareableCount: Int { consent.forEvaluation ? DiverFeedbackExport.shareable(records).count : 0 }

    func load() async {
        do {
            records = try await service.repository.fetchAll()
            consent = service.consent
            errorMessage = nil
        } catch {
            errorMessage = DiverFeedbackRepositoryError.message(for: error)
        }
    }

    func updateConsent(_ consent: FeedbackConsent) async {
        do {
            try await service.setConsent(consent)
            self.consent = consent
            await load()
        } catch {
            self.consent = service.consent
            errorMessage = DiverFeedbackRepositoryError.message(for: error)
        }
    }

    /// Builds the export and its file for the preview; the share sheet opens only from there.
    func prepareExport() async {
        do {
            let export = try await service.makeExport()
            self.export = export
            exportURL = try service.writeExport(export)
            errorMessage = nil
        } catch {
            export = nil
            exportURL = nil
            errorMessage = DiverFeedbackRepositoryError.message(for: error)
        }
    }
}
