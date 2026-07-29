import SwiftUI

struct RootView: View {
    @Bindable var router: AppRouter
    let identificationService: any MarineLifeIdentificationService
    let savedRepository: any SavedSpeciesRepository

    var body: some View {
        NavigationStack(path: $router.path) {
            HomeView(router: router)
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route)
                }
        }
        .tint(.appPrimary)
    }

    @ViewBuilder private func destination(for route: AppRoute) -> some View {
        switch route {
        case .descriptionSearch:
            DescriptionSearchView(viewModel: .init(service: identificationService), router: router)
        case .photoIdentification:
            PhotoIdentificationView(viewModel: .init(service: identificationService), router: router)
        case .identificationResults(let source):
            IdentificationResultsView(viewModel: .init(source: source, service: identificationService), router: router)
        case .speciesDetail(let species, let confidence):
            SpeciesDetailView(viewModel: .init(species: species, confidence: confidence, repository: savedRepository))
        case .savedSpecies:
            SavedSpeciesView(viewModel: .init(repository: savedRepository), router: router)
        }
    }
}

#Preview { RootView(router: AppRouter(), identificationService: MockMarineLifeIdentificationService(delay: .zero), savedRepository: InMemorySavedSpeciesRepository()) }
