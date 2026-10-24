import SwiftUI

struct IdentificationResultsView: View {
    @State var viewModel: IdentificationResultsViewModel
    let router: AppRouter

    private var hasResults: Bool {
        if case .loaded(_) = viewModel.state { return true }
        return false
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                LoadingStateView(message: viewModel.loadingMessage).accessibilityIdentifier("resultsLoading")
            case .empty:
                EmptyStateView(title: "No useful matches", message: "No useful match was found in the offline catalogue. Add more detail about color, shape, markings, size, habitat, behavior, depth, or location and try again.", systemImage: "magnifyingglass")
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
                    // At most ten results, so a plain stack: every result exists (and keeps its identifier
                    // in the accessibility tree) even when, at large text sizes, it starts below the screen.
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                            Label(viewModel.resultsSummary, systemImage: "sparkle.magnifyingglass")
                                .labelStyle(CompactLabelStyle())
                                .font(.subheadline.weight(.semibold))
                            if viewModel.packMetadata?.isExperimental == true {
                                Label(AppCopy.draftCatalogueWarning, systemImage: "exclamationmark.triangle.fill")
                                    .labelStyle(CompactLabelStyle())
                                    .font(.footnote.bold()).foregroundStyle(Color.appWarning)
                            }
                            Text(AppCopy.matchStrengthDisclaimer)
                                .font(.footnote).foregroundStyle(Color.appTextSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .appCard()
                        ForEach(matches) { match in
                            Button { router.navigate(to: .speciesDetail(match.species, match)) } label: {
                                SpeciesResultCard(match: match)
                            }
                            .buttonStyle(AppCardButtonStyle())
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
        .sensoryFeedback(.success, trigger: hasResults) { _, hasResults in hasResults }
        // A detail push cancels this view task, but the router still owns the flow.
        .task {
            await router.waitForSessionUpdates()
            guard !Task.isCancelled else { return }
            await viewModel.loadIfNeeded()
        }
    }
}
