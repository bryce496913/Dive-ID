import Observation
import SwiftUI

@MainActor @Observable
final class DescriptionSearchViewModel {
    var descriptionText = ""
    var isCreatingSession = false
    var errorMessage: String?
    var pack: OfflineIdentificationPackMetadata?
    private let sessionStore: any IdentificationSessionStore
    private let catalog: any MarineSpeciesCatalogRepository
    private let regionRepository: any SelectedDiveRegionRepository

    init(sessionStore: any IdentificationSessionStore, catalog: any MarineSpeciesCatalogRepository, regionRepository: any SelectedDiveRegionRepository) { self.sessionStore = sessionStore; self.catalog = catalog; self.regionRepository = regionRepository }

    func load() async {
        let selectedID = await regionRepository.selectedRegion()
        pack = try? await catalog.availablePacks().first { $0.id == selectedID }
    }

    var normalizedDescription: String { descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { (5...2000).contains(normalizedDescription.count) && !isCreatingSession }

    func submit() async -> UUID? {
        guard canSubmit else { return nil }
        isCreatingSession = true
        errorMessage = nil
        defer { isCreatingSession = false }
        do {
            let region = await regionRepository.selectedRegion()
            let request = IdentificationRequest(source: .description(normalizedDescription), context: IdentificationContext(region: region))
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
                Text("Include color, size, markings, shape, behavior, habitat, depth, and where you saw it.")
                    .foregroundStyle(Color.appTextSecondary)
                if let pack = viewModel.pack { HStack { VStack(alignment: .leading) { Text("Dive region: \(pack.displayName)").font(.headline); Text("\(pack.speciesCount) species available offline") } ; Spacer(); Button("Change") { router.navigate(to: .offlineRegions) } }.padding().background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }
                ZStack(alignment: .topLeading) {
                    if viewModel.descriptionText.isEmpty {
                        Text("Example: Small blue fish, approximately 20 cm, seen on a shallow reef in the selected region.")
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
                Label("Your description is processed on this device using Dive ID’s offline marine-life catalogue.", systemImage: "iphone")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                Label("Offline results are limited to species currently included with this version of Dive ID.", systemImage: "tray.full")
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
        .task { await viewModel.load() }
    }
}
