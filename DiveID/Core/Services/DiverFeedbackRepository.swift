import Foundation

/// Diver feedback, stored only on this device. One record per search attempt: answering
/// again replaces that attempt's record.
protocol DiverFeedbackRepository: Sendable {
    func fetchAll() async throws -> [DiverFeedbackRecord]
    func save(_ record: DiverFeedbackRecord) async throws -> DiverFeedbackRecord
    /// Applies the diver's current consent to every stored record.
    func applyConsent(_ consent: FeedbackConsent) async throws
}

actor InMemoryDiverFeedbackRepository: DiverFeedbackRepository {
    private var values: [DiverFeedbackRecord]
    init(initial: [DiverFeedbackRecord] = []) { values = initial }
    func fetchAll() -> [DiverFeedbackRecord] { values.sorted { $0.createdAt > $1.createdAt } }
    func save(_ record: DiverFeedbackRecord) -> DiverFeedbackRecord { values = DiverFeedbackFile.upserting(record, into: values); return record }
    func applyConsent(_ consent: FeedbackConsent) { values = DiverFeedbackFile.applying(consent, to: values) }
}

struct DiverFeedbackFile: Codable, Sendable {
    let schemaVersion: Int
    var records: [DiverFeedbackRecord]

    /// The existing record for the same attempt keeps its ID and creation time.
    static func upserting(_ record: DiverFeedbackRecord, into values: [DiverFeedbackRecord]) -> [DiverFeedbackRecord] {
        var values = values
        if let index = values.firstIndex(where: { $0.attemptID == record.attemptID }) {
            var updated = values[index]
            updated.answer = record.answer; updated.claimedSpeciesID = record.claimedSpeciesID
            updated.broadRegion = record.broadRegion; updated.approximateDepth = record.approximateDepth
            updated.uncertainty = record.uncertainty; updated.hasPhotoToSend = record.hasPhotoToSend
            updated.consentForEvaluation = record.consentForEvaluation; updated.consentForPublication = record.consentForPublication
            updated.updatedAt = record.updatedAt
            values[index] = updated
        } else {
            values.append(record)
        }
        return values
    }

    static func applying(_ consent: FeedbackConsent, to values: [DiverFeedbackRecord]) -> [DiverFeedbackRecord] {
        values.map { record in
            var record = record
            record.consentForEvaluation = consent.forEvaluation
            record.consentForPublication = consent.forPublication
            return record
        }
    }
}

enum DiverFeedbackRepositoryError: Error, LocalizedError {
    case unsupportedSchema, corruptData, storageUnavailable, initializationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Feedback storage uses a newer format. Update Dive ID and retry."
        case .corruptData: "Feedback storage could not be read. Your file has not been reset. Retry, or restore a readable backup."
        case .storageUnavailable, .initializationFailed:
            "Feedback storage is unavailable. Check available device storage and retry. Offline search is still available."
        }
    }

    static func message(for error: Error) -> String {
        (error as? Self)?.errorDescription
            ?? "Feedback storage could not be accessed. Check available device storage and retry."
    }
}

/// Production storage. A failed initialization is reported; the next operation retries
/// the same persistent factory, never memory storage (as PersistentSavedIdentificationRepository).
actor PersistentDiverFeedbackRepository: DiverFeedbackRepository {
    private let makeRepository: @Sendable () throws -> JSONDiverFeedbackRepository
    private var repository: JSONDiverFeedbackRepository?

    init(makeRepository: @escaping @Sendable () throws -> JSONDiverFeedbackRepository = { try JSONDiverFeedbackRepository() }) {
        self.makeRepository = makeRepository
    }

    private func persistentRepository() throws -> JSONDiverFeedbackRepository {
        if let repository { return repository }
        do {
            let repository = try makeRepository()
            self.repository = repository
            return repository
        } catch {
            throw DiverFeedbackRepositoryError.initializationFailed
        }
    }

    func fetchAll() async throws -> [DiverFeedbackRecord] { try await persistentRepository().fetchAll() }
    func save(_ record: DiverFeedbackRecord) async throws -> DiverFeedbackRecord { try await persistentRepository().save(record) }
    func applyConsent(_ consent: FeedbackConsent) async throws { try await persistentRepository().applyConsent(consent) }
}

actor JSONDiverFeedbackRepository: DiverFeedbackRepository {
    static let schemaVersion = 1
    private let fileURL: URL
    private let fileManager: FileManager
    private let writeData: @Sendable (Data, URL) throws -> Void

    init(fileURL: URL? = nil, fileManager: FileManager = .default,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in try data.write(to: url, options: .atomic) }) throws {
        self.fileManager = fileManager
        self.writeData = writeData
        if let fileURL {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.fileURL = fileURL
            return
        }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw DiverFeedbackRepositoryError.storageUnavailable
        }
        let appDirectory = directory.appendingPathComponent("DiveID", isDirectory: true)
        try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        self.fileURL = appDirectory.appendingPathComponent("diver-feedback.json")
    }

    func fetchAll() throws -> [DiverFeedbackRecord] { try read().sorted { $0.createdAt > $1.createdAt } }
    func save(_ record: DiverFeedbackRecord) throws -> DiverFeedbackRecord {
        try write(DiverFeedbackFile.upserting(record, into: read()))
        return record
    }
    func applyConsent(_ consent: FeedbackConsent) throws { try write(DiverFeedbackFile.applying(consent, to: read())) }

    private func read() throws -> [DiverFeedbackRecord] {
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch CocoaError.fileReadNoSuchFile { return [] }
        guard let envelope = try? DiverFeedbackExport.decoder.decode(DiverFeedbackFile.self, from: data) else {
            throw DiverFeedbackRepositoryError.corruptData
        }
        guard envelope.schemaVersion == Self.schemaVersion else { throw DiverFeedbackRepositoryError.unsupportedSchema }
        return envelope.records
    }

    private func write(_ records: [DiverFeedbackRecord]) throws {
        let data = try DiverFeedbackExport.encoder.encode(DiverFeedbackFile(schemaVersion: Self.schemaVersion, records: records))
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic replacement keeps the previous file if the write fails.
        try writeData(data, fileURL)
    }
}

/// Per-install feedback state: a random participant code (made once, not derived from the
/// device), whether a search has happened yet, and the diver's consent choices.
protocol FeedbackSettings: AnyObject, Sendable {
    var participantCode: String { get }
    var hasSearchedBefore: Bool { get set }
    var consentDecided: Bool { get set }
    var consent: FeedbackConsent { get set }
}

final class UserDefaultsFeedbackSettings: FeedbackSettings, @unchecked Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var participantCode: String {
        if let code = defaults.string(forKey: "feedbackParticipantCode") { return code }
        let code = Self.makeParticipantCode()
        defaults.set(code, forKey: "feedbackParticipantCode")
        return code
    }
    var hasSearchedBefore: Bool {
        get { defaults.bool(forKey: "feedbackHasSearchedBefore") }
        set { defaults.set(newValue, forKey: "feedbackHasSearchedBefore") }
    }
    var consentDecided: Bool {
        get { defaults.bool(forKey: "feedbackConsentDecided") }
        set { defaults.set(newValue, forKey: "feedbackConsentDecided") }
    }
    var consent: FeedbackConsent {
        get { FeedbackConsent(forEvaluation: defaults.bool(forKey: "feedbackConsentEvaluation"),
                              forPublication: defaults.bool(forKey: "feedbackConsentPublication")) }
        set {
            defaults.set(newValue.forEvaluation, forKey: "feedbackConsentEvaluation")
            defaults.set(newValue.forPublication, forKey: "feedbackConsentPublication")
        }
    }

    /// "DIVER-" and 8 random characters with no look-alikes (no 0/O, 1/I/L).
    static func makeParticipantCode() -> String {
        let alphabet = Array("23456789ABCDEFGHJKMNPQRSTUVWXYZ")
        var generator = SystemRandomNumberGenerator()
        return "DIVER-" + String((0..<8).map { _ in alphabet.randomElement(using: &generator)! })
    }
}

final class InMemoryFeedbackSettings: FeedbackSettings, @unchecked Sendable {
    let participantCode: String
    var hasSearchedBefore: Bool
    var consentDecided: Bool
    var consent: FeedbackConsent
    init(participantCode: String = "DIVER-TEST0001", hasSearchedBefore: Bool = false, consentDecided: Bool = false, consent: FeedbackConsent = .init()) {
        self.participantCode = participantCode; self.hasSearchedBefore = hasSearchedBefore
        self.consentDecided = consentDecided; self.consent = consent
    }
}
