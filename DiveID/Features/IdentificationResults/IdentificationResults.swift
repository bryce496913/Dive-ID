import SwiftUI

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
                        if viewModel.packMetadata?.isExperimental == true {
                            Label("Experimental draft catalogue — identities and biological details have not been verified", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.bold()).foregroundStyle(Color.appWarning)
                        }
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
        // A detail push cancels this view task, but the router still owns the flow.
        .task {
            await router.waitForSessionUpdates()
            guard !Task.isCancelled else { return }
            await viewModel.loadIfNeeded()
        }
    }
}
