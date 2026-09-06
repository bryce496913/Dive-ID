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

    init() {
        let catalogRepository = BundleMarineSpeciesCatalogRepository()
        self.catalogRepository = catalogRepository
        self.regionRepository = UserDefaultsSelectedDiveRegionRepository()
        // Deliberately opt-in: production installations continue to use BM25 unless a
        // developer build sets DiveIDExperimentalSemanticSearch to true.
        let retrievalEngine: DescriptionRetrievalEngine = UserDefaults.standard.bool(forKey: "DiveIDExperimentalSemanticSearch")
            ? .experimentalCoreML : .productionBM25
        identificationService = LocalMarineLifeIdentificationService(
            catalogRepository: catalogRepository,
            searchEngine: ConfiguredDescriptionSearchEngine(selection: retrievalEngine)
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
        }
    }
}
