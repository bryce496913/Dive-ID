import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router = AppRouter()
    private let identificationService: any MarineLifeIdentificationService
    private let savedRepository: any SavedIdentificationRepository
    private let sessionStore: any IdentificationSessionStore
    private let photoProcessor: any PhotoProcessingService
    private let features = FeatureAvailability.current

    init() {
        let catalogRepository = BundleMarineSpeciesCatalogRepository()
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
                features: features
            )
            .preferredColorScheme(.dark)
        }
    }
}
