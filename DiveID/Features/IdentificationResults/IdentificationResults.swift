import Observation
import SwiftUI

@MainActor @Observable
final class IdentificationResultsViewModel {
    let sessionID: UUID
    private(set) var state: LoadState<[IdentificationMatch]> = .idle
    private(set) var packMetadata: OfflineIdentificationPackMetadata?
    private let service: any MarineLifeIdentificationService
    private let sessionStore: any IdentificationSessionStore
    private let catalog: any MarineSpeciesCatalogRepository
    private var loadTask: Task<Void, Never>?

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
        guard case .idle = state, loadTask == nil else { return }
        await execute()
    }

    func retry() async {
        guard loadTask == nil else { return }
        if case .failed = state { await execute() }
    }

    private func execute() async {
        guard loadTask == nil else { return }
        state = .loading
        let task = Task { [service, sessionStore, catalog, sessionID] in
            do {
                let request = try await sessionStore.request(for: sessionID)
                if let packID = request.context.region {
                    if let packs = try? await catalog.availablePacks() {
                        for metadata in packs where metadata.id == packID {
                            packMetadata = metadata
                            break
                        }
                    }
                }
                if let cached = try await sessionStore.result(for: sessionID) {
                    apply(cached.matches)
                    return
                }
                let photo: ProcessedPhoto?
                if case .processedPhoto(let reference) = request.source {
                    photo = try await sessionStore.photo(for: reference)
                } else {
                    photo = nil
                }
                let matches = try await service.identify(request: request, processedPhoto: photo)
                try Task.checkCancellation()
                let displayed = normalized(matches).map { value in
                    var value = value; value.sourceSessionID = sessionID
                    if case .description(let description) = request.source { value.observationDescription = description }
                    return value
                }
                try await sessionStore.saveResult(.init(matches: displayed, completedAt: Date()), for: sessionID)
                apply(displayed)
            } catch is CancellationError {
                state = .idle
            } catch let error as LocalIdentificationError {
                state = .failed(Self.message(for: error), retryable: error != .unsupportedSource && { if case .regionMismatch = error { return false }; return true }())
            } catch {
                state = .failed("Identification could not be completed locally. Please try again.", retryable: true)
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private static func message(for error: LocalIdentificationError) -> String {
        switch error {
        case .invalidDescription:
            "Add more detail about the animal before trying again."
        case .catalogUnavailable:
            "The offline species catalogue could not be loaded."
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

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        if case .loading = state { state = .idle }
    }
}

struct IdentificationResultsView: View {
    @State var viewModel: IdentificationResultsViewModel
    let router: AppRouter

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                LoadingStateView(message: viewModel.loadingMessage).accessibilityIdentifier("resultsLoading")
            case .empty:
                EmptyStateView(title: "No useful matches", message: "No useful match was found in the current offline catalogue. Add more detail about color, shape, markings, size, habitat, behavior, depth, or location and try again.")
                    .accessibilityIdentifier("resultsEmpty")
            case .failed(let message, let retryable):
                ErrorStateView(message: message, retry: retryable ? { Task { await viewModel.retry() } } : nil)
                    .accessibilityIdentifier("resultsFailure")
            case .loaded(let matches):
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Text(viewModel.resultsSummary)
                            .font(.footnote).foregroundStyle(Color.appTextSecondary)
                        Text("Match strength reflects similarity to the clues in your description. It is not scientific certainty.")
                            .font(.footnote).foregroundStyle(Color.appTextSecondary)
                        ForEach(matches) { match in
                            Button { router.navigate(to: .speciesDetail(match.species, match)) } label: {
                                SpeciesResultCard(match: match)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("result_\(match.species.id)")
                        }
                        Text("These are offline match suggestions, not confirmed identifications. Compare distinguishing features and confirm important sightings with a qualified local guide or trusted reference.")
                            .font(.footnote).foregroundStyle(Color.appTextSecondary).padding(.top)
                    }
                    .padding()
                }
            }
        }
        .appScreenBackground()
        .navigationTitle("Possible Matches")
        .task { await viewModel.loadIfNeeded() }
    }
}
