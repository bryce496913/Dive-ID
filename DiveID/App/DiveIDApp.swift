import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router: AppRouter
    private let identificationService: any MarineLifeIdentificationService
    private let savedRepository: any SavedIdentificationRepository
    private let sessionStore: any IdentificationSessionStore
    private let photoProcessor: any PhotoProcessingService
    private let catalogRepository: any MarineSpeciesCatalogRepository
    private let regionRepository: any SelectedDiveRegionRepository
    private let features = FeatureAvailability.current
    private let retrievalEngine: DescriptionRetrievalEngine
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
        savedRepository = PersistentSavedIdentificationRepository()
        let sessionStore = InMemoryIdentificationSessionStore()
        self.sessionStore = sessionStore
        self.router = AppRouter(sessionStore: sessionStore)
        photoProcessor = DefaultPhotoProcessingService()
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
                features: features
            )
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom, spacing: 0) {
#if DEBUG
                // Reserve space so diagnostics cannot cover or intercept search controls.
                DebugSemanticSearchStatusView(selection: retrievalEngine, reporter: semanticDiagnostics)
                    .allowsHitTesting(false)
#elseif DIVEID_INTERNAL
                // An Internal build must never be mistaken for Release on screen.
                InternalBuildBanner().allowsHitTesting(false)
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
