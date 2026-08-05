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
        let parser = LocalObservationParser()
        let ranker = LocalSpeciesRanker()
        identificationService = LocalMarineLifeIdentificationService(
            catalogRepository: catalogRepository,
            parser: parser,
            ranker: ranker
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
