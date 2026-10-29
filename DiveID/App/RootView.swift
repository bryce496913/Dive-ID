import SwiftUI

struct RootView: View {
    @Bindable var router: AppRouter
    let identificationService: any MarineLifeIdentificationService
    let savedRepository: any SavedLogRepository
    let sessionStore: any IdentificationSessionStore
    let photoProcessor: any PhotoProcessingService
    let catalogRepository: any MarineSpeciesCatalogRepository
    let regionRepository: any SelectedDiveRegionRepository
    let features: FeatureAvailability
    let feedback: DiverFeedbackService

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView(router: router, features: features, viewModel: .init(catalog: catalogRepository, regionRepository: regionRepository))
                .navigationDestination(for: AppRoute.self) { route in destination(for: route) }
        }
        .tint(.appAccent)
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .descriptionSearch:
            DescriptionSearchView(viewModel: .init(sessionStore: sessionStore, catalog: catalogRepository, regionRepository: regionRepository, feedback: feedback), router: router)
        case .photoIdentification:
            // Guard the route itself so a programmatic push cannot open a disabled feature.
            if features.photoIdentificationEnabled {
                PhotoIdentificationView(
                    viewModel: .init(sessionStore: sessionStore, photoProcessor: photoProcessor,
                                     packLoader: SelectedPackLoader(catalog: catalogRepository, regionRepository: regionRepository),
                                     feedback: feedback),
                    router: router
                )
            } else {
                EmptyStateView(title: "Photo identification unavailable", message: "Photo identification is not yet available.", systemImage: "camera")
                    .appScreenBackground()
                    .navigationTitle("Identify From Photo")
            }
        case .identificationResults(let sessionID):
            IdentificationResultsView(
                viewModel: router.resultsModel(sessionID: sessionID, service: identificationService, catalog: catalogRepository),
                router: router,
                feedback: FeedbackPromptViewModel(sessionID: sessionID, service: feedback)
            )
        case .speciesDetail(let species, let match):
            SpeciesDetailView(viewModel: .init(species: species, match: match, repository: savedRepository),
                              feedback: match?.sourceSessionID.map { FeedbackPromptViewModel(sessionID: $0, service: feedback) })
        case .savedIdentification(let saved):
            SpeciesDetailView(viewModel: .init(saved: saved, repository: savedRepository))
        case .savedIdentifications:
            DiveLogView(viewModel: router.diveLogModel(repository: savedRepository, catalog: catalogRepository), router: router)
        case .dive(let id):
            DiveDetailView(viewModel: router.diveLogModel(repository: savedRepository, catalog: catalogRepository), diveID: id, router: router)
        case .offlineRegions:
            OfflineRegionsView(
                viewModel: .init(catalog: catalogRepository, selection: regionRepository),
                selectionDidChange: { router.goBack() }
            )
        case .credits:
            CreditsView(catalog: catalogRepository, feedback: FeedbackSharingViewModel(service: feedback))
        case .fieldGuide:
            FieldGuideView(viewModel: router.fieldGuideModel(catalog: catalogRepository), router: router)
        case .fieldGuideGroup(let id):
            FieldGuideGroupView(viewModel: router.fieldGuideModel(catalog: catalogRepository), groupID: id, router: router)
        case .speciesCatalogue:
            SpeciesCatalogueView(viewModel: .init(catalog: catalogRepository, regionRepository: regionRepository), router: router)
        }
    }
}

#Preview {
    let store = InMemoryIdentificationSessionStore()
    RootView(
        router: AppRouter(sessionStore: store),
        identificationService: MockMarineLifeIdentificationService(delay: .zero),
        savedRepository: InMemorySavedIdentificationRepository(),
        sessionStore: store,
        photoProcessor: DefaultPhotoProcessingService(),
        catalogRepository: BundleMarineSpeciesCatalogRepository(),
        regionRepository: UserDefaultsSelectedDiveRegionRepository(),
        features: .init(photoIdentificationEnabled: false),
        feedback: DiverFeedbackService(repository: InMemoryDiverFeedbackRepository(), settings: InMemoryFeedbackSettings())
    )
}
