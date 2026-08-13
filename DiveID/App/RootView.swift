import SwiftUI

struct RootView: View {
    @Bindable var router: AppRouter
    let identificationService: any MarineLifeIdentificationService
    let savedRepository: any SavedIdentificationRepository
    let sessionStore: any IdentificationSessionStore
    let photoProcessor: any PhotoProcessingService
    let catalogRepository: any MarineSpeciesCatalogRepository
    let regionRepository: any SelectedDiveRegionRepository
    let features: FeatureAvailability

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
            DescriptionSearchView(viewModel: .init(sessionStore: sessionStore, catalog: catalogRepository, regionRepository: regionRepository), router: router)
        case .photoIdentification:
            PhotoIdentificationView(
                viewModel: .init(sessionStore: sessionStore, photoProcessor: photoProcessor),
                router: router
            )
        case .identificationResults(let sessionID):
            IdentificationResultsView(
                viewModel: .init(sessionID: sessionID, service: identificationService, sessionStore: sessionStore),
                router: router
            )
        case .speciesDetail(let species, let match):
            SpeciesDetailView(viewModel: .init(species: species, match: match, repository: savedRepository))
        case .savedIdentification(let saved):
            SpeciesDetailView(viewModel: .init(saved: saved, repository: savedRepository))
        case .savedSpecies:
            SavedSpeciesView(viewModel: .init(repository: savedRepository), router: router)
        case .offlineRegions:
            OfflineRegionsView(viewModel: .init(catalog: catalogRepository, selection: regionRepository))
        }
    }
}

#Preview {
    RootView(
        router: AppRouter(),
        identificationService: MockMarineLifeIdentificationService(delay: .zero),
        savedRepository: InMemorySavedIdentificationRepository(),
        sessionStore: InMemoryIdentificationSessionStore(),
        photoProcessor: DefaultPhotoProcessingService(),
        catalogRepository: BundleMarineSpeciesCatalogRepository(),
        regionRepository: UserDefaultsSelectedDiveRegionRepository()
        , features: .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: false)
    )
}
