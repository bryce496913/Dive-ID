import Foundation

protocol MarineLifeIdentificationService: Sendable {
    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch]
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
