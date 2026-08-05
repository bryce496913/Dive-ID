import Observation
import SwiftUI

@MainActor @Observable
final class SpeciesDetailViewModel {
    let species: Species
    let match: IdentificationMatch?
    var isSaved = false
    var errorMessage: String?
    private(set) var savedIdentificationID: UUID?
    private(set) var isUpdatingSavedState = false
    private let repository: any SavedIdentificationRepository

    init(species: Species, match: IdentificationMatch?, repository: any SavedIdentificationRepository) {
        self.species = species
        self.match = match
        self.repository = repository
        savedIdentificationID = nil
    }

    init(saved: SavedIdentification, repository: any SavedIdentificationRepository) { species = saved.species; match = saved.match; self.repository = repository; savedIdentificationID = saved.id; isSaved = true }

    func load() async {
        guard savedIdentificationID == nil else { return }
        do { if let session = match?.sourceSessionID { let saved = try await repository.savedIdentification(sourceSessionID: session, speciesID: species.id); savedIdentificationID = saved?.id; isSaved = saved != nil } }
        catch { errorMessage = "Saved status could not be loaded." }
    }

    func toggleSaved() async {
        guard !isUpdatingSavedState else { return }
        isUpdatingSavedState = true
        defer { isUpdatingSavedState = false }
        do {
            if isSaved {
                if savedIdentificationID == nil, let session = match?.sourceSessionID { savedIdentificationID = try await repository.savedIdentification(sourceSessionID: session, speciesID: species.id)?.id }
                guard let id = savedIdentificationID else { errorMessage = "The saved identification could not be found."; return }
                try await repository.remove(id: id)
                savedIdentificationID = nil
                isSaved = false
            } else if let match {
                let persisted = try await repository.save(SavedIdentification(match: match))
                savedIdentificationID = persisted.id
                isSaved = true
            }
            errorMessage = nil
        } catch {
            errorMessage = "The saved identification could not be updated. Your previous saved state was kept."
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
                        Text(match.matchStrength.displayName).font(.subheadline).foregroundStyle(Color.appTextSecondary)
                        if match.taxonomicResolution != .species { Text("Taxonomic level: \(match.taxonomicResolution.rawValue.capitalized)").font(.caption).foregroundStyle(Color.appTextSecondary) }
                    }
                }
                PrimaryActionButton(title: viewModel.isSaved ? "Remove from Saved" : "Save Identification") {
                    Task { await viewModel.toggleSaved() }
                }
                .accessibilityIdentifier("toggleSaved")
                .disabled(viewModel.isUpdatingSavedState)
                if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.appError) }
                DetailSection(title: "Identification summary", text: viewModel.species.summary)
                DetailSection(title: "Visual characteristics", text: viewModel.species.visualCharacteristics.joined(separator: " • "))
                DetailSection(title: "Typical habitat", text: viewModel.species.habitat)
                DetailSection(title: "General geographic range", text: viewModel.species.geographicRange)
                if let occurrence = viewModel.species.regionalOccurrence { DetailSection(title: "Regional occurrence", text: occurrence.capitalized) }
                if !viewModel.species.appearanceVariants.isEmpty { DetailSection(title: "Life-stage differences", text: viewModel.species.appearanceVariants.map { $0.description }.joined(separator: " • ")) }
                if !viewModel.species.similarSpecies.isEmpty { DetailSection(title: "Similar species", text: viewModel.species.similarSpecies.map { $0.distinguishingText }.joined(separator: " • ")) }
                if let image = viewModel.species.bundledImage { DetailSection(title: "Image credit", text: "\(image.creatorName) — \(image.sourceName), \(image.licenseName) (\(image.licenseURL))") }
                if let pack = viewModel.species.packContext { DetailSection(title: "Offline pack", text: pack.displayName) }
                if let match = viewModel.match, !match.explanation.isEmpty { DetailSection(title: "Why it matched", text: match.explanation) }
                if let match = viewModel.match, !match.observationDescription.isEmpty { DetailSection(title: "Original observation", text: match.observationDescription) }
                if let match = viewModel.match, !match.cautions.isEmpty { DetailSection(title: "Cautions and missing evidence", text: match.cautions.joined(separator: " • ")) }
                DetailSection(title: "Accuracy", text: "AI-generated suggestions may be inaccurate. Confirm important sightings with a qualified local guide or trusted reference.")
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
