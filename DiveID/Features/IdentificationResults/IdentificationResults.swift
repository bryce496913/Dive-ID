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
                EmptyStateView(title: "No useful matches", message: "No useful match was found in the offline catalogue. Add more detail about color, shape, markings, size, habitat, behavior, depth, or location and try again.")
                    .accessibilityIdentifier("resultsEmpty")
#if DEBUG || DIVEID_INTERNAL
                    .onAppear { InternalSearchDiagnostics.shared.queryFinished(.noResults) }
#endif
            case .failed(let message, let retryable):
                ErrorStateView(message: message, retry: retryable ? { Task { await viewModel.retry() } } : nil)
                    .accessibilityIdentifier("resultsFailure")
#if DEBUG || DIVEID_INTERNAL
                    .onAppear { InternalSearchDiagnostics.shared.queryFinished(.failed) }
#endif
            case .loaded(let matches):
                ScrollView {
                    LazyVStack(spacing: AppTheme.Spacing.m) {
                        Text(viewModel.resultsSummary)
                            .font(.footnote).foregroundStyle(Color.appTextSecondary)
                        if viewModel.packMetadata?.isExperimental == true {
                            Label(AppCopy.draftCatalogueWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote.bold()).foregroundStyle(Color.appWarning)
                        }
                        Text(AppCopy.matchStrengthDisclaimer)
                            .font(.footnote).foregroundStyle(Color.appTextSecondary)
                        ForEach(matches) { match in
                            Button { router.navigate(to: .speciesDetail(match.species, match)) } label: {
                                SpeciesResultCard(match: match)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("result_\(match.species.id)")
                        }
                        Text(AppCopy.accuracyDisclaimer)
                            .font(.footnote).foregroundStyle(Color.appTextSecondary).padding(.top)
                    }
                    .padding()
                }
#if DEBUG || DIVEID_INTERNAL
                .onAppear { InternalSearchDiagnostics.shared.queryFinished(.results) }
#endif
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
