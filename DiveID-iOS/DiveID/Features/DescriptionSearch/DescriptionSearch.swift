import Observation
import SwiftUI

@MainActor @Observable final class DescriptionSearchViewModel {
    var descriptionText = ""; var isLoading = false; var errorMessage: String?
    private let service: any MarineLifeIdentificationService
    init(service: any MarineLifeIdentificationService) { self.service = service }
    var canSubmit: Bool { !descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func submit() async -> Bool { guard canSubmit else { return false }; isLoading = true; errorMessage = nil; defer { isLoading = false }; do { _ = try await service.identify(from: descriptionText); return true } catch is CancellationError { return false } catch { errorMessage = "Demo matches could not be prepared. Please try again."; return false } }
}

struct DescriptionSearchView: View {
    @State var viewModel: DescriptionSearchViewModel; let router: AppRouter
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 16) { Text("Describe color, shape, markings, size, and where you saw the animal.").foregroundStyle(.secondary); ZStack(alignment: .topLeading) { if viewModel.descriptionText.isEmpty { Text("Example: Small silver fish with yellow fins, a dark stripe through its eye, and a pointed nose. Seen near coral in shallow water.").foregroundStyle(.tertiary).padding(12) }; TextEditor(text: $viewModel.descriptionText).frame(minHeight: 190).scrollContentBackground(.hidden).padding(6).accessibilityIdentifier("descriptionText") }.background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)); Text("\(viewModel.descriptionText.count) characters").font(.caption).frame(maxWidth: .infinity, alignment: .trailing).foregroundStyle(.secondary); Label("Demo results are currently generated from local mock data.", systemImage: "hammer").font(.footnote).foregroundStyle(.secondary); if let error = viewModel.errorMessage { Text(error).foregroundStyle(.red) }; PrimaryActionButton(title: "Find Matches", isLoading: viewModel.isLoading, disabled: !viewModel.canSubmit) { Task { if await viewModel.submit() { router.navigate(to: .identificationResults(.description(viewModel.descriptionText))) } } }.accessibilityIdentifier("findMatches") }.padding() }.background(Color.appBackground).navigationTitle("Describe What You Saw") }
}
#Preview("Empty") { NavigationStack { DescriptionSearchView(viewModel: .init(service: MockMarineLifeIdentificationService(delay: .zero)), router: AppRouter()) } }
