import Observation
import SwiftUI

@MainActor @Observable
final class SpeciesDetailViewModel {
    let species: Species
    let match: IdentificationMatch?
    var isSaved = false
    var errorMessage: String?
    private let repository: any SavedSpeciesRepository

    init(species: Species, match: IdentificationMatch?, repository: any SavedSpeciesRepository) {
        self.species = species
        self.match = match
        self.repository = repository
    }

    func load() async {
        do { isSaved = try await repository.isSaved(species) }
        catch { errorMessage = "Saved status could not be loaded." }
    }

    func toggleSaved() async {
        do {
            if isSaved { try await repository.remove(species) } else { try await repository.save(species) }
            isSaved.toggle()
            errorMessage = nil
        } catch {
            errorMessage = "Saved species could not be updated. Your previous saved state was kept."
        }
    }
}

struct SpeciesDetailView: View {
    @State var viewModel: SpeciesDetailViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SpeciesArtwork(species: viewModel.species).frame(height: 250)
                VStack(alignment: .leading, spacing: 6) {
                    Text(viewModel.species.commonName).font(.largeTitle.bold())
                    Text(viewModel.species.scientificName).font(.title3).italic().foregroundStyle(Color.appTextSecondary)
                    if let match = viewModel.match {
                        Text(match.matchStrength.rawValue).font(.subheadline).foregroundStyle(Color.appTextSecondary)
                    }
                }
                PrimaryActionButton(title: viewModel.isSaved ? "Remove from Saved" : "Save Species") {
                    Task { await viewModel.toggleSaved() }
                }
                .accessibilityIdentifier("toggleSaved")
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.appError) }
                DetailSection(title: "Identification summary", text: viewModel.species.summary)
                DetailSection(title: "Visual characteristics", text: viewModel.species.visualCharacteristics.joined(separator: " • "))
                DetailSection(title: "Typical habitat", text: viewModel.species.habitat)
                DetailSection(title: "General geographic range", text: viewModel.species.geographicRange)
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle(viewModel.species.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }
}

private struct DetailSection: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(Color.appTextSecondary)
        }
    }
}
