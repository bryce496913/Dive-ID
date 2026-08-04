import Observation
import SwiftUI

@MainActor @Observable final class SavedSpeciesViewModel {
    var identifications: [SavedIdentification] = []; var isLoading = true; var errorMessage: String?
    private let repository: any SavedIdentificationRepository
    init(repository: any SavedIdentificationRepository) { self.repository = repository }
    func load() async { do { identifications = try await repository.fetchAll(); isLoading = false } catch { errorMessage = "Saved identifications could not be loaded."; isLoading = false } }
    func remove(_ item: SavedIdentification) async { do { try await repository.remove(id: item.id); await load() } catch { errorMessage = "The identification could not be removed." } }
}

struct SavedSpeciesView: View {
    @State var viewModel: SavedSpeciesViewModel; let router: AppRouter
    var body: some View { Group { if viewModel.isLoading { LoadingStateView() } else if let error = viewModel.errorMessage { ErrorStateView(message: error) } else if viewModel.identifications.isEmpty { EmptyStateView(title: "No saved identifications", message: "Save a possible match to retain why it matched.") } else { List { ForEach(viewModel.identifications) { item in Button { router.navigate(to: .savedIdentification(item)) } label: { HStack { SpeciesArtwork(species: item.species).frame(width: 58, height: 58); VStack(alignment: .leading) { Text(item.species.commonName); Text(item.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary); Text("\(item.matchStrength.displayName) · \(item.identifiedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption); Text(item.explanation.isEmpty ? item.observationDescription : item.explanation).lineLimit(2).font(.caption).foregroundStyle(Color.appTextSecondary) } } }.buttonStyle(.plain).listRowBackground(Color.appSurface).swipeActions { Button("Remove", role: .destructive) { Task { await viewModel.remove(item) } } } } }.scrollContentBackground(.hidden) } }.appScreenBackground().navigationTitle("Saved Identifications").task { await viewModel.load() } }
}
