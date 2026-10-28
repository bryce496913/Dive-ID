import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router: AppRouter
    private let identificationService: any MarineLifeIdentificationService
    private let savedRepository: any SavedLogRepository
    private let sessionStore: any IdentificationSessionStore
    private let photoProcessor: any PhotoProcessingService
    private let catalogRepository: any MarineSpeciesCatalogRepository
    private let regionRepository: any SelectedDiveRegionRepository
    private let features = FeatureAvailability.current
    private let retrievalEngine: DescriptionRetrievalEngine
    private let feedback: DiverFeedbackService
#if DEBUG
    private let semanticDiagnostics: DebugSemanticDiagnosticsReporter
#endif

    init() {
        let catalogRepository = BundleMarineSpeciesCatalogRepository()
        self.catalogRepository = catalogRepository
        self.regionRepository = UserDefaultsSelectedDiveRegionRepository()
        // Deliberately opt-in: production installations continue to use BM25 unless a
        // developer build sets DiveIDExperimentalSemanticSearch to true.
        #if DEBUG
        retrievalEngine = UserDefaults.standard.bool(forKey: "DiveIDExperimentalSemanticSearch")
            ? .experimentalCoreML : .productionDefault
        let semanticDiagnostics = DebugSemanticDiagnosticsReporter()
        self.semanticDiagnostics = semanticDiagnostics
        #else
        // Experimental selection and its diagnostics are both excluded from production.
        retrievalEngine = .productionDefault
        #endif
        #if DEBUG
        let searchEngine = ConfiguredDescriptionSearchEngine(selection: retrievalEngine, diagnostics: semanticDiagnostics)
        #else
        let searchEngine = ConfiguredDescriptionSearchEngine(selection: retrievalEngine)
        #endif
        identificationService = LocalMarineLifeIdentificationService(
            catalogRepository: catalogRepository,
            searchEngine: searchEngine
        )
        savedRepository = Self.makeSavedRepository()
        let sessionStore = InMemoryIdentificationSessionStore()
        self.sessionStore = sessionStore
        self.router = AppRouter(sessionStore: sessionStore)
        photoProcessor = DefaultPhotoProcessingService()
        feedback = Self.makeFeedbackService()
    }

    /// UI tests pass -resetDiveLogForUITests for an empty dive log in a temporary file (Debug
    /// only), so real saved identifications are never touched.
    private static func makeSavedRepository() -> PersistentSavedIdentificationRepository {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetDiveLogForUITests") {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-saved-identifications.json")
            try? FileManager.default.removeItem(at: file)
            return PersistentSavedIdentificationRepository { try JSONSavedIdentificationRepository(fileURL: file) }
        }
#endif
        return PersistentSavedIdentificationRepository()
    }

    /// Feedback is stored only on this device. UI tests pass -resetFeedbackForUITests for a
    /// fresh install's feedback state (Debug only), without touching real feedback.
    @MainActor private static func makeFeedbackService() -> DiverFeedbackService {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetFeedbackForUITests") {
            let suite = "DiveIDUITestFeedback"
            UserDefaults().removePersistentDomain(forName: suite)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-diver-feedback.json")
            try? FileManager.default.removeItem(at: file)
            return DiverFeedbackService(
                repository: PersistentDiverFeedbackRepository(makeRepository: { try JSONDiverFeedbackRepository(fileURL: file) }),
                settings: UserDefaultsFeedbackSettings(defaults: UserDefaults(suiteName: suite) ?? .standard))
        }
#endif
        return DiverFeedbackService(repository: PersistentDiverFeedbackRepository(), settings: UserDefaultsFeedbackSettings())
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                router: router,
                identificationService: identificationService,
                savedRepository: savedRepository,
                sessionStore: sessionStore,
                photoProcessor: photoProcessor,
                catalogRepository: catalogRepository,
                regionRepository: regionRepository,
                features: features,
                feedback: feedback
            )
            .preferredColorScheme(.dark)
            .fontDesign(.rounded)
            .safeAreaInset(edge: .bottom, spacing: 0) {
#if DEBUG
                // Reserve space so diagnostics cannot cover or intercept search controls. Its text
                // size is capped: at the largest accessibility sizes the strip grew to about 280 pt
                // and squeezed the screen until Find Matches spilled underneath it.
                DebugSemanticSearchStatusView(selection: retrievalEngine, reporter: semanticDiagnostics)
                    .dynamicTypeSize(...DynamicTypeSize.large)
                    .allowsHitTesting(false)
#elseif DIVEID_INTERNAL
                // An Internal build must never be mistaken for Release on screen.
                InternalBuildBanner().dynamicTypeSize(...DynamicTypeSize.large).allowsHitTesting(false)
#endif
            }
        }
    }
}

#if DIVEID_INTERNAL && !DEBUG
/// Shown on every screen of the Internal configuration: optimized like Release, but
/// opening the draft development catalogue. Never compiled into Release or Debug.
private struct InternalBuildBanner: View {
    var body: some View {
        Text("Internal build · draft catalogue · not Release")
            .font(.caption2.monospaced().bold())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.appWarning)
            .foregroundStyle(.black)
            .accessibilityIdentifier("internalBuildBanner")
    }
}
#endif
