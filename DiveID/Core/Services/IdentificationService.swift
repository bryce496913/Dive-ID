import Foundation

protocol MarineLifeIdentificationService: Sendable {
    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch]
    /// The matches plus, for a photo search, what the recognizer did.
    func identifyOutcome(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> IdentificationOutcome
}

extension MarineLifeIdentificationService {
    func identifyOutcome(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> IdentificationOutcome {
        IdentificationOutcome(matches: try await identify(request: request, processedPhoto: processedPhoto))
    }
}

struct IdentificationOutcome: Sendable {
    var matches: [IdentificationMatch]
    var photoSummary: PhotoMatchSummary? = nil
}

/// What a photo search's recognizer did, shown with the results and kept for feedback.
struct PhotoMatchSummary: Hashable, Sendable {
    let recognizerID: String
    let recognizerVersion: String
    /// Species in the searched pack the recognizer can suggest, of `catalogueSpeciesCount`.
    let coveredSpeciesCount: Int
    let catalogueSpeciesCount: Int
    /// No confident photo match: the recognizer abstained or its best match was below the threshold.
    let abstained: Bool
    /// A test recognizer: its results are placeholders.
    let isPlaceholder: Bool
    /// The diver's extra text was searched too.
    let usedDescription: Bool
}

enum MockServiceError: Error { case demonstrationFailure }

struct MockMarineLifeIdentificationService: MarineLifeIdentificationService {
    enum Mode: Sendable { case success, empty, failure }

    let delay: Duration
    let mode: Mode

    init(delay: Duration = .milliseconds(450), shouldFail: Bool = false) {
        self.delay = delay
        mode = shouldFail ? .failure : .success
    }

    init(delay: Duration = .milliseconds(450), mode: Mode) {
        self.delay = delay
        self.mode = mode
    }

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        if case .processedPhoto = request.source, processedPhoto == nil {
            throw IdentificationSessionStoreError.photoNotFound
        }
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        if mode == .failure { throw MockServiceError.demonstrationFailure }
        if mode == .empty { return [] }
        return zip(MockSpecies.all, stride(from: 0.94, through: 0.49, by: -0.05)).map {
            IdentificationMatch(id: $0.id, species: $0, score: $1, scoreKind: .relativeMatch)
        }
    }
}
