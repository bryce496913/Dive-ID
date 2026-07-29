import Foundation

protocol MarineLifeIdentificationService: Sendable {
    func identify(from description: String) async throws -> [IdentificationMatch]
    func identify(from imageData: Data) async throws -> [IdentificationMatch]
}

enum MockServiceError: Error { case demonstrationFailure }

struct MockMarineLifeIdentificationService: MarineLifeIdentificationService {
    let delay: Duration
    let shouldFail: Bool
    init(delay: Duration = .milliseconds(450), shouldFail: Bool = false) { self.delay = delay; self.shouldFail = shouldFail }
    func identify(from description: String) async throws -> [IdentificationMatch] { try await results() }
    func identify(from imageData: Data) async throws -> [IdentificationMatch] { try await results() }
    private func results() async throws -> [IdentificationMatch] {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        if shouldFail { throw MockServiceError.demonstrationFailure }
        return zip(MockSpecies.all, stride(from: 0.94, through: 0.49, by: -0.05)).map {
            IdentificationMatch(id: $0.id, species: $0, confidence: $1)
        }.prefix(10).sorted { $0.confidence > $1.confidence }
    }
}
