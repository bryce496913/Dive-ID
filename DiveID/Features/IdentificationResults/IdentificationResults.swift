import SwiftUI

struct IdentificationResultsView: View {
    @State var viewModel: IdentificationResultsViewModel
    let router: AppRouter
    /// "Was this right?" for this search; nil where feedback is unavailable (previews, tests).
    @State var feedback: FeedbackPromptViewModel? = nil

    private var hasResults: Bool {
        if case .loaded(_) = viewModel.state { return true }
        return false
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle, .loading:
                LoadingStateView(message: viewModel.loadingMessage).accessibilityIdentifier("resultsLoading")
            case .empty where viewModel.isPhotoAbstention:
                ScrollView {
                    VStack(spacing: AppTheme.Spacing.l) {
                        EmptyStateView(title: AppCopy.noConfidentPhotoMatchTitle, message: AppCopy.noConfidentPhotoMatchMessage, systemImage: "photo")
                        photoFooter
                    }
                    .padding()
                }
                .accessibilityIdentifier("photoNoConfidentMatch")
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
                            if let photo = viewModel.photoSummary {
                                if photo.isPlaceholder {
                                    Label(AppCopy.placeholderRecognizerWarning, systemImage: "exclamationmark.triangle.fill")
                                        .labelStyle(CompactLabelStyle())
                                        .font(.footnote.bold()).foregroundStyle(Color.appWarning)
                                        .accessibilityIdentifier("photoPlaceholderWarning")
                                }
                                if photo.abstained {
                                    Text(AppCopy.photoResultsFromDescription).font(.footnote.bold())
                                }
                                Text(AppCopy.photoMatchStrengthDisclaimer)
                                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                            } else {
                                Text(AppCopy.matchStrengthDisclaimer)
                                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                            }
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
                        if viewModel.isPhotoSearch { photoFooter }
                        // Below the matches, after the diver has seen them all.
                        if let feedback, feedback.isAvailable {
                            FeedbackPrompt(model: feedback, matches: matches)
                        }
                    }
                    .padding()
                }
                // Records the results as displayed; it never changes them.
                .task(id: matches.map(\.id)) { feedback?.recordShown(matches, photo: viewModel.photoSummary) }
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

    /// Photo searches: what the recognizer covers, and the way back to describing.
    @ViewBuilder private var photoFooter: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            if let coverage = viewModel.photoCoverageText {
                Text(coverage).font(.footnote).foregroundStyle(Color.appTextSecondary)
                    .accessibilityIdentifier("photoCoverage")
            }
            Button(AppCopy.describeItInstead, systemImage: "text.bubble") { router.navigate(to: .descriptionSearch) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("describeInstead")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
