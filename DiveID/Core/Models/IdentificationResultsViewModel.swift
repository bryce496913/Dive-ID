import Foundation
import Observation

@MainActor @Observable
final class IdentificationResultsViewModel {
    let sessionID: UUID
    private(set) var state: LoadState<[IdentificationMatch]> = .idle
    private(set) var packMetadata: OfflineIdentificationPackMetadata?
    /// Set for a photo search once it has run.
    private(set) var photoSummary: PhotoMatchSummary?
    /// The search as asked: its unchanged description and any clues added to it.
    private(set) var request: IdentificationRequest?
    /// What the added clues did, for a refined search once it has run.
    private(set) var refinedText: RefinedSearchText?
    private(set) var isStartingRefinedSearch = false
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
        guard let packMetadata else { return "Searching the selected dive region…" }
        return "Searching the \(packMetadata.displayName) dive region…"
    }

    var isPhotoSearch: Bool { photoSummary != nil }

    /// "Photo matching covers N of M species…", for photo searches.
    var photoCoverageText: String? {
        photoSummary.map { AppCopy.photoCoverage(covered: $0.coveredSpeciesCount, total: $0.catalogueSpeciesCount) }
    }

    /// No confident photo match, and nothing from the diver's text either.
    var isPhotoAbstention: Bool {
        guard let photoSummary, photoSummary.abstained, case .empty = state else { return false }
        return true
    }

    var resultsSummary: String {
        guard let packMetadata else { return "Matches from the selected dive region" }
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
                self.request = request
                if case .description(let description) = request.source, request.context.refinement != nil {
                    refinedText = await RefinedSearchText.compose(original: description, refinement: request.context.refinement)
                    try checkOwnership(id)
                }
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
                    photoSummary = cached.photoSummary
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
                let outcome = try await service.identifyOutcome(request: request, processedPhoto: photo)
                try checkOwnership(id)
                let displayed = normalized(outcome.matches).map { value in
                    var value = value; value.sourceSessionID = sessionID
                    if case .description(let description) = request.source {
                        value.observationDescription = description  // as written, never with the added clues
                        value.refinement = request.context.refinement
                    }
                    return value
                }
                try await sessionStore.saveResult(.init(matches: displayed, completedAt: Date(), photoSummary: outcome.photoSummary), for: sessionID)
                try checkOwnership(id)
                photoSummary = outcome.photoSummary
                apply(displayed)
            } catch is CancellationError {
                if loadID == id { state = .idle }
            } catch let error as LocalIdentificationError {
                guard loadID == id, !Task.isCancelled else { return }
                state = .failed(Self.message(for: error), retryable: error != .unsupportedSource && error != .photoRecognizerUnavailable && { if case .photoMatchingUnavailable = error { return false }; return true }() && { if case .regionMismatch = error { return false }; return true }())
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

    static func message(for error: LocalIdentificationError,
                        includesDiagnostics: Bool = BuildChannel.current.showsDiagnosticCodes) -> String {
        switch error {
        case .invalidDescription:
            "Add more detail about the animal before trying again."
        case .catalogUnavailable:
            AppCopy.catalogueLoadFailed
        case .catalogueLoadFailed(let failure):
            includesDiagnostics
                ? "\(AppCopy.catalogueLoadFailed)\nDiagnostic: \(failure.code.rawValue)"
                : AppCopy.catalogueLoadFailed
        case .unsupportedSource:
            "Photo identification is not available in this offline version yet."
        case .photoRecognizerUnavailable:
            "Photo matching isn't available for this dive region yet. Try describing the animal instead."
        case .photoMatchingUnavailable(let code):
            includesDiagnostics
                ? "\(AppCopy.photoMatchingUnavailable)\nDiagnostic: \(code)"
                : AppCopy.photoMatchingUnavailable
        case .regionMismatch(let selected, let mentioned):
            "Your description mentions \(mentioned), but the selected dive region covers the \(selected.rawValue.capitalized). Choose another dive region and try again."
        }
    }

    // MARK: Refining a description search

    /// Description searches can always be refined, whatever the results.
    var canRefine: Bool {
        guard let request, case .description = request.source else { return false }
        switch state { case .loaded, .empty: return true; default: return false }
    }

    /// The clues this search already used (empty for the first search).
    var currentRefinement: SearchRefinement { request?.context.refinement ?? SearchRefinement() }
    var isRefined: Bool { request?.context.refinement != nil }
    /// The first, unrefined search in this chain.
    var rootSessionID: UUID { request?.context.refinesSessionID ?? sessionID }

    /// The results are close or thin: worth inviting the diver to add details.
    var isAmbiguous: Bool {
        switch state {
        case .empty: return true
        case .loaded(let matches):
            guard let first = matches.first else { return true }
            if first.informationLevel == .limited || first.informationLevel == .insufficient { return true }
            if first.matchStrength != .strong && first.matchStrength != .good { return true }
            if matches.count > 1, first.score - matches[1].score < 0.08 { return true }
            return false
        default: return false
        }
    }

    /// The questions to ask, most useful first (RefinementQuestions.order).
    func refinementQuestions(parser: some ObservationParsing = LocalObservationParser()) async -> [SearchRefinement.Dimension] {
        guard let request, case .description(let description) = request.source else { return SearchRefinement.Dimension.allCases }
        let candidates: [Species]
        if case .loaded(let matches) = state { candidates = matches.map(\.species) } else { candidates = [] }
        return RefinementQuestions.order(observation: await parser.parse(description), candidates: candidates)
    }

    /// A new search: the same description, region and context, with these clues. Returns its
    /// session; nil when nothing would change or a refined search is already starting.
    func startRefinedSearch(_ refinement: SearchRefinement) async -> UUID? {
        let wanted = refinement.isEmpty ? nil : refinement
        guard !isStartingRefinedSearch, let request, case .description = request.source, wanted != request.context.refinement else { return nil }
        isStartingRefinedSearch = true
        defer { isStartingRefinedSearch = false }
        var context = request.context
        context.refinement = wanted
        context.refinesSessionID = rootSessionID
        let refined = IdentificationRequest(source: request.source, context: context)
        return try? await sessionStore.createSession(for: refined, photo: nil)
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
#if DEBUG || DIVEID_INTERNAL
        if case .loading = state { InternalSearchDiagnostics.shared.queryFinished(.cancelled) }
#endif
        loadID = nil
        loadTask?.cancel()
        loadTask = nil
        if case .loading = state { state = .idle }
    }
}

