import SwiftUI

struct RootView: View {
    @Bindable var router: AppRouter
    let identificationService: any MarineLifeIdentificationService
    let savedRepository: any SavedSpeciesRepository
    let sessionStore: any IdentificationSessionStore
    let photoProcessor: any PhotoProcessingService

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView(router: router)
                .navigationDestination(for: AppRoute.self) { route in destination(for: route) }
        }
        .tint(.appAccent)
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .descriptionSearch:
            DescriptionSearchView(viewModel: .init(sessionStore: sessionStore), router: router)
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
        case .savedSpecies:
            SavedSpeciesView(viewModel: .init(repository: savedRepository), router: router)
        }
    }
}

#Preview {
    RootView(
        router: AppRouter(),
        identificationService: MockMarineLifeIdentificationService(delay: .zero),
        savedRepository: InMemorySavedSpeciesRepository(),
        sessionStore: InMemoryIdentificationSessionStore(),
        photoProcessor: DefaultPhotoProcessingService()
    )
}
