import Foundation

/// What the diver said about a search's results. Never preselected, never inferred.
enum FeedbackAnswer: Hashable, Sendable {
    /// "Yes — this one": the diver's own claim. It is not verification evidence; a curator
    /// assigns identities independently (Data/Evaluation/IndependentDiverCollection.md).
    case claimed(speciesID: UUID)
    case noneOfThese
    case notSure

    var kind: String {
        switch self {
        case .claimed: "claimedSpecies"
        case .noneOfThese: "none"
        case .notSure: "notSure"
        }
    }

    var claimedSpeciesID: UUID? {
        if case .claimed(let id) = self { return id }
        return nil
    }
}

/// One displayed result, as the diver saw it.
struct FeedbackShownResult: Codable, Hashable, Sendable {
    let rank: Int
    let speciesID: UUID
}

enum DepthUnit: String, Codable, CaseIterable, Sendable { case metres, feet }

struct ApproximateDepth: Codable, Hashable, Sendable {
    let value: Double
    let unit: DepthUnit
}

/// The optional details a diver may add. Empty strings are stored as nil.
struct FeedbackDetails: Hashable, Sendable {
    var broadRegion = ""
    var depthText = ""
    var depthUnit: DepthUnit = .metres
    var uncertainty = ""
    var hasPhotoToSend = false

    var approximateDepth: ApproximateDepth? {
        let text = depthText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text), value >= 0, value.isFinite else { return nil }
        return ApproximateDepth(value: value, unit: depthUnit)
    }

    static func optional(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}

/// One search, recorded when Find Matches is pressed. It never feeds back into search.
struct FeedbackSearchAttempt: Hashable, Sendable {
    let attemptID: UUID
    let sessionID: UUID
    /// Exactly as typed: not trimmed, not edited.
    let originalDescription: String
    let firstSearchOfInstall: Bool
    /// The earlier attempt this one re-searched after the diver saw its results.
    let researchOfAttemptID: UUID?
    /// True when the text differs from that earlier attempt's.
    let editedAfterSeeingResults: Bool
    let packID: String
    let catalogueVersion: Int
    var shownResults: [FeedbackShownResult] = []
}

/// A diver's feedback on one search, stored only on this device.
struct DiverFeedbackRecord: Codable, Identifiable, Hashable, Sendable {
    var id: UUID { feedbackID }
    let feedbackID: UUID
    let attemptID: UUID
    let createdAt: Date
    var updatedAt: Date
    let appVersion: String
    let appBuild: String
    let buildChannel: String
    let packID: String
    let catalogueVersion: Int
    let participantCode: String
    let originalDescription: String
    let firstSearchOfInstall: Bool
    let researchOfAttemptID: UUID?
    let editedAfterSeeingResults: Bool
    let shownResults: [FeedbackShownResult]
    var answer: String
    var claimedSpeciesID: UUID?
    var broadRegion: String?
    var approximateDepth: ApproximateDepth?
    var uncertainty: String?
    var hasPhotoToSend: Bool
    var consentForEvaluation: Bool
    var consentForPublication: Bool
    /// True once the diver has seen app results: every search after the first of the install.
    let priorExposure: Bool

    init(attempt: FeedbackSearchAttempt, answer: FeedbackAnswer, details: FeedbackDetails, consent: FeedbackConsent,
         participantCode: String, app: AppInfo, feedbackID: UUID = UUID(), now: Date = Date()) {
        self.feedbackID = feedbackID
        attemptID = attempt.attemptID
        createdAt = now
        updatedAt = now
        appVersion = app.version
        appBuild = app.build
        buildChannel = app.channel
        packID = attempt.packID
        catalogueVersion = attempt.catalogueVersion
        self.participantCode = participantCode
        originalDescription = attempt.originalDescription
        firstSearchOfInstall = attempt.firstSearchOfInstall
        researchOfAttemptID = attempt.researchOfAttemptID
        editedAfterSeeingResults = attempt.editedAfterSeeingResults
        shownResults = Array(attempt.shownResults.prefix(10))
        self.answer = answer.kind
        claimedSpeciesID = answer.claimedSpeciesID
        broadRegion = FeedbackDetails.optional(details.broadRegion)
        approximateDepth = details.approximateDepth
        uncertainty = FeedbackDetails.optional(details.uncertainty)
        hasPhotoToSend = details.hasPhotoToSend
        consentForEvaluation = consent.forEvaluation
        consentForPublication = consent.forPublication
        priorExposure = !attempt.firstSearchOfInstall
    }
}

/// The diver's two separate, optional consents. Both default to off.
struct FeedbackConsent: Hashable, Sendable {
    var forEvaluation = false
    var forPublication = false
}

/// Version, build and channel recorded with each feedback record. No device identifiers.
struct AppInfo: Hashable, Sendable {
    let version: String
    let build: String
    let channel: String

    static let current = AppInfo(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
        channel: BuildChannel.current.rawValue)
}

/// The file "Share my feedback" produces (schema: Data/Evaluation/DiverFeedbackExport.v1.md).
struct DiverFeedbackExport: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    static let formatName = "diveid-diver-feedback"
    let schemaVersion: Int
    let format: String
    let exportedAt: Date
    let participantCode: String
    let note: String
    let records: [DiverFeedbackRecord]

    static let evidenceNote = "Diver feedback from the Dive ID app. claimedSpeciesID is the diver's own answer after seeing app results; it is not identity verification evidence. Only records with consentForEvaluation = true are included."

    /// Only records the diver consented to evaluation use; oldest first. Each record's own
    /// flag isn't enough: with `evaluationConsent` (the current setting) off, nothing is
    /// included, even if an earlier withdrawal didn't reach every stored record.
    init(records: [DiverFeedbackRecord], evaluationConsent: Bool, participantCode: String, now: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        format = Self.formatName
        exportedAt = now
        self.participantCode = participantCode
        note = Self.evidenceNote
        self.records = evaluationConsent ? Self.shareable(records).sorted { $0.createdAt < $1.createdAt } : []
    }

    static func shareable(_ records: [DiverFeedbackRecord]) -> [DiverFeedbackRecord] { records.filter(\.consentForEvaluation) }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func encoded() throws -> Data { try Self.encoder.encode(self) }
}
