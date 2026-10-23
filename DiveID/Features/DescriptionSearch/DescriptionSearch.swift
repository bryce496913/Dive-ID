import Observation
import SwiftUI

@MainActor @Observable
final class DescriptionSearchViewModel {
    var descriptionText = ""
    var isCreatingSession = false
    var errorMessage: String?
    var packState: SelectedPackState = .notLoaded
    private let sessionStore: any IdentificationSessionStore
    private let packLoader: SelectedPackLoader
#if DEBUG || DIVEID_INTERNAL
    let diagnostics = InternalSearchDiagnostics.shared
#endif

    init(sessionStore: any IdentificationSessionStore, catalog: any MarineSpeciesCatalogRepository, regionRepository: any SelectedDiveRegionRepository) { self.sessionStore = sessionStore; packLoader = SelectedPackLoader(catalog: catalog, regionRepository: regionRepository) }

    /// Loads the selected pack's metadata, then starts preparing its search index in the
    /// background (off the main thread), so the first search usually finds it ready.
    func load() async {
        packState = await packLoader.load()
        guard let pack else { return }
#if DEBUG || DIVEID_INTERNAL
        SearchIndexPreparation.start(packID: pack.id, catalog: packLoader.catalog, diagnostics: diagnostics)
#else
        SearchIndexPreparation.start(packID: pack.id, catalog: packLoader.catalog)
#endif
    }

    var pack: OfflineIdentificationPackMetadata? { packState.pack }
    var normalizedDescription: String { descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { pack != nil && (3...2000).contains(normalizedDescription.count) && !isCreatingSession }

    func submit() async -> UUID? {
        guard canSubmit, let pack else { return nil }
        isCreatingSession = true
        errorMessage = nil
        defer { isCreatingSession = false }
        do {
            let request = IdentificationRequest(source: .description(normalizedDescription), context: IdentificationContext(region: pack.id))
            return try await sessionStore.createSession(for: request, photo: nil)
        } catch IdentificationSessionStoreError.capacityReached {
            errorMessage = AppCopy.sessionCapacityReached
            return nil
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
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                Text("Include color, size, markings, shape, behavior, habitat, depth, and where you saw it.")
                    .foregroundStyle(Color.appTextSecondary)
                if let pack = viewModel.pack { HStack { VStack(alignment: .leading) { Text("Dive region: \(pack.displayName)").font(.headline); Text("\(pack.speciesCount) species available offline") } ; Spacer(); Button("Change") { router.navigate(to: .offlineRegions) } }.padding().background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }
                else { SelectedPackStatusView(state: viewModel.packState, retry: { Task { await viewModel.load() } }, changeRegion: { router.navigate(to: .offlineRegions) }) }
                ZStack(alignment: .topLeading) {
                    if viewModel.descriptionText.isEmpty {
                        Text("Example: Small blue fish, approximately 20 cm, seen on a shallow reef in the selected region.")
                            .foregroundStyle(Color.appTextSecondary.opacity(0.7)).padding(AppTheme.Spacing.m)
                    }
                    TextEditor(text: $viewModel.descriptionText)
                        .frame(minHeight: 190).scrollContentBackground(.hidden).padding(AppTheme.Spacing.xs)
                        .focused($isEditorFocused)
                        .accessibilityIdentifier("descriptionText")
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
                Text("\(viewModel.descriptionText.count) characters")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .trailing)
                    .foregroundStyle(Color.appTextSecondary)
                Label("Your description is processed on this device using Dive ID’s offline catalogue.", systemImage: "iphone")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
                Label("Offline results are limited to species currently included with this version of Dive ID.", systemImage: "tray.full")
                    .font(.footnote).foregroundStyle(Color.appTextSecondary)
#if DEBUG || DIVEID_INTERNAL
                // In the scrolling content, so it never moves or covers the pinned search controls.
                if let pack = viewModel.pack { InternalSearchDiagnosticsView(packID: pack.id, diagnostics: viewModel.diagnostics) }
#endif
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        // Pinned outside the scroll view so the keyboard can never cover it: it sits directly
        // above the keyboard when open, and above any app-wide bottom inset when closed.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.appError) }
                PrimaryActionButton(title: "Find Matches", isLoading: viewModel.isCreatingSession, disabled: !viewModel.canSubmit) {
                    // One tap both dismisses the keyboard and submits.
                    isEditorFocused = false
                    Task {
#if DEBUG || DIVEID_INTERNAL
                        if let pack = viewModel.pack { viewModel.diagnostics.querySubmitted(packID: pack.id) }
#endif
                        await router.waitForSessionUpdates()
                        if let sessionID = await viewModel.submit() {
                            router.navigate(to: .identificationResults(sessionID: sessionID))
                        } else {
#if DEBUG || DIVEID_INTERNAL
                            viewModel.diagnostics.queryFinished(.failed)
#endif
                        }
                    }
                }
                .accessibilityIdentifier("findMatches")
            }
            .padding(.horizontal)
            .padding(.vertical, AppTheme.Spacing.s)
            .background(Color.appBackground.ignoresSafeArea(.container, edges: .bottom))
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditorFocused = false }
                    .accessibilityIdentifier("dismissKeyboard")
            }
        }
        .appScreenBackground()
        .navigationTitle("Describe What You Saw")
        .task(id: router.path) { await viewModel.load() }
    }
}
