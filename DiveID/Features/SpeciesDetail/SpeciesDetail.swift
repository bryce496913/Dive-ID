import Observation
import SwiftUI

@MainActor @Observable final class SpeciesDetailViewModel {
    let species: Species; let confidence: Double?; var isSaved = false; var errorMessage: String?
    private let repository: any SavedSpeciesRepository
    init(species: Species, confidence: Double?, repository: any SavedSpeciesRepository) { self.species = species; self.confidence = confidence; self.repository = repository }
    func load() async { isSaved = await repository.isSaved(species) }
    func toggleSaved() async { do { if isSaved { try await repository.remove(species) } else { try await repository.save(species) }; isSaved.toggle() } catch { errorMessage = "Saved species could not be updated." } }
}

struct SpeciesDetailView: View {
    @State var viewModel: SpeciesDetailViewModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) { SpeciesArtwork(species: viewModel.species).frame(height: 250); VStack(alignment: .leading, spacing: 6) { Text(viewModel.species.commonName).font(.largeTitle.bold()); Text(viewModel.species.scientificName).font(.title3).italic().foregroundStyle(.secondary); if let confidence = viewModel.confidence { Text("Demo confidence: \(confidence, format: .percent.precision(.fractionLength(0)))").font(.subheadline).foregroundStyle(.secondary) } }; PrimaryActionButton(title: viewModel.isSaved ? "Remove from Saved" : "Save Species") { Task { await viewModel.toggleSaved() } }; DetailSection(title: "Identification summary", text: viewModel.species.summary); DetailSection(title: "Visual characteristics", text: viewModel.species.visualCharacteristics.joined(separator: " • ")); DetailSection(title: "Typical habitat", text: viewModel.species.habitat); DetailSection(title: "General geographic range", text: viewModel.species.geographicRange) }.padding() }.background(Color.appBackground).navigationTitle(viewModel.species.commonName).navigationBarTitleDisplayMode(.inline).task { await viewModel.load() } }
}
private struct DetailSection: View { let title: String; let text: String; var body: some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary) } } }
