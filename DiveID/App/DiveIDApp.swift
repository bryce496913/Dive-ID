import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router = AppRouter()
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
            ? .experimentalCoreML : .productionBM25
        let semanticDiagnostics = DebugSemanticDiagnosticsReporter()
        self.semanticDiagnostics = semanticDiagnostics
        #else
        // Experimental selection and its diagnostics are both excluded from production.
        retrievalEngine = .productionBM25
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
        savedRepository = (try? JSONSavedIdentificationRepository()) ?? InMemorySavedIdentificationRepository()
        sessionStore = InMemoryIdentificationSessionStore()
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
            .overlay(alignment: .bottom) {
#if DEBUG
                DebugSemanticSearchStatusView(selection: retrievalEngine, reporter: semanticDiagnostics)
#endif
            }
        }
    }
}
