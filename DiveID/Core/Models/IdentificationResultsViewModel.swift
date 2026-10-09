import Foundation
import Observation

@MainActor @Observable
final class IdentificationResultsViewModel {
    let sessionID: UUID
    private(set) var state: LoadState<[IdentificationMatch]> = .idle
    private(set) var packMetadata: OfflineIdentificationPackMetadata?
    private let service: any MarineLifeIdentificationService
    private let sessionStore: any IdentificationSessionStore
    private let catalog: any MarineSpeciesCatalogRepository
    private var loadTask: Task<Void, Never>?
    private var loadID: UUID?

    init(sessionID: UUID, service: any MarineLifeIdentificationService, sessionStore: any IdentificationSessionStore, catalog: any MarineSpeciesCatalogRepository = BundleMarineSpeciesCatalogRepository()) {
        self.sessionID = sessionID
        self.service = service
        self.sessionStore = sessionStore
        self.catalog = catalog
    }

    var loadingMessage: String {
        guard let packMetadata else { return "Searching the selected offline pack…" }
        return "Searching the \(packMetadata.displayName) offline pack…"
    }

    var resultsSummary: String {
        guard let packMetadata else { return "Matches from the selected offline pack" }
        return "Matches from \(packMetadata.speciesCount.formatted()) locally stored \(packMetadata.displayName) records"
    }

    func loadIfNeeded() async {
        guard !Task.isCancelled, case .idle = state, loadTask == nil else { return }
        await execute()
    }

    func retry() async {
        guard !Task.isCancelled, loadTask == nil else { return }
        if case .failed = state { await execute() }
    }

    private func execute() async {
        guard !Task.isCancelled, loadTask == nil else { return }
        state = .loading
        let id = UUID()
        loadID = id
        let task = Task { [service, sessionStore, catalog, sessionID] in
            do {
                let request = try await sessionStore.request(for: sessionID)
                try checkOwnership(id)
                if let packID = request.context.region {
                    if let packs = try? await catalog.availablePacks() {
                        try checkOwnership(id)
                        for metadata in packs where metadata.id == packID {
                            packMetadata = metadata
                            break
                        }
                    }
                }
                try checkOwnership(id)
                if let cached = try await sessionStore.result(for: sessionID) {
                    try checkOwnership(id)
                    apply(cached.matches)
                    return
                }
                try checkOwnership(id)
                let photo: ProcessedPhoto?
                if case .processedPhoto(let reference) = request.source {
                    photo = try await sessionStore.photo(for: reference)
                } else {
                    photo = nil
                }
                try checkOwnership(id)
                let matches = try await service.identify(request: request, processedPhoto: photo)
                try checkOwnership(id)
                let displayed = normalized(matches).map { value in
                    var value = value; value.sourceSessionID = sessionID
                    if case .description(let description) = request.source { value.observationDescription = description }
                    return value
                }
                try await sessionStore.saveResult(.init(matches: displayed, completedAt: Date()), for: sessionID)
                try checkOwnership(id)
                apply(displayed)
            } catch is CancellationError {
                if loadID == id { state = .idle }
            } catch let error as LocalIdentificationError {
                guard loadID == id, !Task.isCancelled else { return }
                state = .failed(Self.message(for: error), retryable: error != .unsupportedSource && { if case .regionMismatch = error { return false }; return true }())
            } catch {
                guard loadID == id, !Task.isCancelled else { return }
                state = .failed("Identification could not be completed locally. Please try again.", retryable: true)
            }
        }
        loadTask = task
        await task.value
        if loadID == id {
            loadTask = nil
            loadID = nil
        }
    }

    static func message(for error: LocalIdentificationError, includesDiagnostics: Bool = {
#if DEBUG
        true
#else
        false
#endif
    }()) -> String {
        switch error {
        case .invalidDescription:
            "Add more detail about the animal before trying again."
        case .catalogUnavailable:
            "The offline species catalogue could not be loaded."
        case .catalogueLoadFailed(let failure):
            includesDiagnostics
                ? "The offline species catalogue could not be loaded.\nDiagnostic: \(failure.code.rawValue)"
                : "The offline species catalogue could not be loaded."
        case .unsupportedSource:
            "Photo identification is not available in this offline version yet."
        case .regionMismatch(let selected, let mentioned):
            "Your description mentions \(mentioned), but the selected offline pack covers the \(selected.rawValue.capitalized). Check the selected dive region and try again."
        }
    }

    private func apply(_ matches: [IdentificationMatch]) {
        let displayed = normalized(matches)
        state = displayed.isEmpty ? .empty : .loaded(displayed)
    }

    private func normalized(_ matches: [IdentificationMatch]) -> [IdentificationMatch] {
        var seen = Set<UUID>()
        return Array(matches.sorted { $0.rank == $1.rank ? $0.score > $1.score : $0.rank < $1.rank }.filter { seen.insert($0.species.id).inserted }.prefix(10))
    }

    private func checkOwnership(_ id: UUID) throws {
        try Task.checkCancellation()
        guard loadID == id else { throw CancellationError() }
    }

    // Owned by the navigation route, not the results view's temporary visibility.
    func cancel() {
        loadID = nil
        loadTask?.cancel()
        loadTask = nil
        if case .loading = state { state = .idle }
    }
}

