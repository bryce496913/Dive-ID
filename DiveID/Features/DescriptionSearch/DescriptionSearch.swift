import Observation
import SwiftUI

@MainActor @Observable
final class DescriptionSearchViewModel {
    var descriptionText = ""
    var isCreatingSession = false
    var errorMessage: String?
    private let sessionStore: any IdentificationSessionStore

    init(sessionStore: any IdentificationSessionStore) { self.sessionStore = sessionStore }

    var normalizedDescription: String { descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { !normalizedDescription.isEmpty && !isCreatingSession }

    func submit() async -> UUID? {
        guard canSubmit else { return nil }
        isCreatingSession = true
        errorMessage = nil
        defer { isCreatingSession = false }
        do {
            let request = IdentificationRequest(source: .description(normalizedDescription))
            return try await sessionStore.createSession(for: request, photo: nil)
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = "The identification session could not be created. Please try again."
            return nil
        }
    }
}

struct DescriptionSearchView: View {
    @State var viewModel: DescriptionSearchViewModel
    let router: AppRouter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Describe color, shape, markings, size, and where you saw the animal.")
                    .foregroundStyle(Color.appTextSecondary)
                ZStack(alignment: .topLeading) {
                    if viewModel.descriptionText.isEmpty {
                        Text("Example: Small silver fish with yellow fins, a dark stripe through its eye, and a pointed nose.")
                            .foregroundStyle(Color.appTextSecondary.opacity(0.7)).padding(12)
                    }
                    TextEditor(text: $viewModel.descriptionText)
                        .frame(minHeight: 190).scrollContentBackground(.hidden).padding(6)
                        .accessibilityIdentifier("descriptionText")
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
                Text("\(viewModel.descriptionText.count) characters")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(Color.appTextSecondary)
                Label("Demo results are generated from local mock data.", systemImage: "hammer")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.appError) }
                PrimaryActionButton(title: "Find Matches", isLoading: viewModel.isCreatingSession, disabled: !viewModel.canSubmit) {
                    Task {
                        if let sessionID = await viewModel.submit() {
                            router.navigate(to: .identificationResults(sessionID: sessionID))
                        }
                    }
                }
                .accessibilityIdentifier("findMatches")
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle("Describe What You Saw")
    }
}
