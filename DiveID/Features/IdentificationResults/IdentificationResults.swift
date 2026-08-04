import Observation
import SwiftUI

@MainActor @Observable
final class IdentificationResultsViewModel {
    let sessionID: UUID
    private(set) var state: LoadState<[IdentificationMatch]> = .idle
    private let service: any MarineLifeIdentificationService
    private let sessionStore: any IdentificationSessionStore
    private var loadTask: Task<Void, Never>?

    init(sessionID: UUID, service: any MarineLifeIdentificationService, sessionStore: any IdentificationSessionStore) {
        self.sessionID = sessionID
        self.service = service
        self.sessionStore = sessionStore
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
        let task = Task { [service, sessionStore, sessionID] in
            do {
                if let cached = try await sessionStore.result(for: sessionID) {
                    apply(cached.matches)
                    return
                }
                let request = try await sessionStore.request(for: sessionID)
                let photo: ProcessedPhoto?
                if case .processedPhoto(let reference) = request.source {
                    photo = try await sessionStore.photo(for: reference)
                } else {
                    photo = nil
                }
                let matches = try await service.identify(request: request, processedPhoto: photo)
                try Task.checkCancellation()
                let displayed = normalized(matches)
                try await sessionStore.saveResult(.init(matches: displayed, completedAt: Date()), for: sessionID)
                apply(displayed)
            } catch is CancellationError {
                state = .idle
            } catch let error as IdentificationServiceError {
                state = .failed(error.userMessage)
            } catch {
                state = .failed("Identification is temporarily unavailable. Please try again.")
            }
        }
        loadTask = task
        await task.value
        loadTask = nil
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
                LoadingStateView().accessibilityIdentifier("resultsLoading")
            case .empty:
                EmptyStateView(title: "No useful matches", message: "We could not find a useful match from that description. Add more detail about color, shape, markings, size, habitat, behavior, depth, or location and try again.")
                    .accessibilityIdentifier("resultsEmpty")
            case .failed(let message):
                ErrorStateView(message: message) { Task { await viewModel.retry() } }
                    .accessibilityIdentifier("resultsFailure")
            case .loaded(let matches):
                ScrollView {
                    LazyVStack(spacing: 12) {
                        Text("Match strength is a ranking aid, not measured identification certainty.")
                            .font(.footnote).foregroundStyle(Color.appTextSecondary)
                        ForEach(matches) { match in
                            Button { router.navigate(to: .speciesDetail(match.species, match)) } label: {
                                SpeciesResultCard(match: match)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("result_\(match.species.id)")
                        }
                        Text("AI-generated suggestions may be inaccurate. Compare distinguishing features and confirm important sightings with a qualified local guide or trusted reference.")
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
