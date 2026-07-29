import Observation
import SwiftUI

@MainActor @Observable final class SavedSpeciesViewModel {
    var species: [Species] = []; var isLoading = true; var errorMessage: String?
    private let repository: any SavedSpeciesRepository
    init(repository: any SavedSpeciesRepository) { self.repository = repository }
    func load() async { do { species = try await repository.fetchSavedSpecies(); isLoading = false } catch { errorMessage = "Saved species could not be loaded."; isLoading = false } }
    func remove(_ item: Species) async { do { try await repository.remove(item); await load() } catch { errorMessage = "The species could not be removed." } }
}

struct SavedSpeciesView: View {
    @State var viewModel: SavedSpeciesViewModel; let router: AppRouter
    var body: some View { Group { if viewModel.isLoading { LoadingStateView() } else if let error = viewModel.errorMessage { ErrorStateView(message: error) } else if viewModel.species.isEmpty { EmptyStateView(title: "No saved species", message: "You have not saved any species yet. Save a possible match to review it later.") } else { List { ForEach(viewModel.species) { species in Button { router.navigate(to: .speciesDetail(species, nil)) } label: { HStack { SpeciesArtwork(species: species).frame(width: 58, height: 58); VStack(alignment: .leading) { Text(species.commonName); Text(species.scientificName).italic().font(.subheadline).foregroundStyle(.secondary) } } }.buttonStyle(.plain).swipeActions { Button("Remove", role: .destructive) { Task { await viewModel.remove(species) } } } } } } }.navigationTitle("Saved Species").task { await viewModel.load() } }
}
