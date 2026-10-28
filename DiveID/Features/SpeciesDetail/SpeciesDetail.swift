import SwiftUI

struct SpeciesDetailView: View {
    @State var viewModel: SpeciesDetailViewModel
    /// Set only when the page was reached from a search's results.
    @State var feedback: FeedbackPromptViewModel? = nil
    @State private var showsAppearance = true
    @State private var showsHabitat = false
    @State private var showsTaxonomy = false
    @ScaledMetric(relativeTo: .largeTitle) private var artworkHeight: CGFloat = 280

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                hero
                // From a search this saves the match; from the field guide, the species alone.
                PrimaryActionButton(title: viewModel.isSaved ? "Remove from Saved Identifications" : "Save Identification") {
                    Task { await viewModel.toggleSaved() }
                }
                .accessibilityIdentifier("toggleSaved")
                .disabled(viewModel.isUpdatingSavedState)
                .sensoryFeedback(.success, trigger: viewModel.isSaved) { _, isSaved in isSaved }
                if let error = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                        Button(AppCopy.tryAgain) { Task { await viewModel.retry() } }
                            .disabled(viewModel.isUpdatingSavedState)
                    }
                }
                // What a diver needs to judge the match comes first: why it matched, what is
                // missing, and how to tell it apart from look-alikes.
                matchEvidence
                if let feedback, feedback.isAvailable {
                    FeedbackThisIsWhatISawButton(model: feedback, species: viewModel.species)
                }
                if !viewModel.species.similarSpecies.isEmpty {
                    DetailCard { DetailSection(title: "Similar species", text: viewModel.species.similarSpecies.map { $0.distinguishingText }.joined(separator: " • ")) }
                }
                DetailCard { DetailSection(title: "Identification summary", text: viewModel.species.summary) }
                appearance
                habitat
                if let taxonomy = viewModel.species.taxonomy {
                    DetailGroup(title: "Taxonomy", isExpanded: $showsTaxonomy) {
                        DetailSection(title: "Classification", text: Self.taxonomyText(taxonomy))
                    }
                }
                // Source attribution stays expanded: the source licence asks for it on each record.
                DetailCard {
                    if let image = viewModel.species.bundledImage { ImageCreditSection(image: image) }
                    if !viewModel.species.dataSources.isEmpty { SourceSection(sources: viewModel.species.dataSources) }
                    if let review = viewModel.species.review {
                        DetailSection(title: "Record review status", text: AppCopy.recordReviewStatus(review))
                    }
                    DetailSection(title: "Accuracy", text: AppCopy.accuracyDisclaimer)
                }
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle(viewModel.species.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    /// The artwork with the name, scientific name and match strength set over its lower edge.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            SpeciesArtwork(species: viewModel.species, showsCaption: false)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                if let match = viewModel.match {
                    MatchStrengthBadge(strength: match.matchStrength)
                }
                Text(viewModel.species.commonName).font(.largeTitle.bold())
                Text(viewModel.species.scientificName).font(.title3).italic().foregroundStyle(Color.appTextPrimary.opacity(0.85))
                if let match = viewModel.match, match.taxonomicResolution != .species {
                    Text("Taxonomic level: \(match.taxonomicResolution.rawValue.capitalized)").font(.caption).foregroundStyle(Color.appTextPrimary.opacity(0.85))
                }
            }
            .padding(AppTheme.Spacing.xl)
        }
        .frame(minHeight: artworkHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.heroRadius, style: .continuous).strokeBorder(Color.appStroke, lineWidth: 1))
        .shadow(color: Color.appAccent.opacity(0.35), radius: 20, y: 8)
    }

    @ViewBuilder
    private var matchEvidence: some View {
        if let match = viewModel.match, !match.explanation.isEmpty || !match.cautions.isEmpty || !match.observationDescription.isEmpty {
            DetailCard {
                if !match.explanation.isEmpty { DetailSection(title: "Why it matched", text: match.explanation) }
                if !match.cautions.isEmpty { DetailSection(title: "Cautions and missing evidence", text: match.cautions.joined(separator: " • ")) }
                if !match.observationDescription.isEmpty { DetailSection(title: "Original observation", text: match.observationDescription) }
            }
        }
    }

    private var appearance: some View {
        let species = viewModel.species
        return DetailGroup(title: "Appearance", isExpanded: $showsAppearance) {
            DetailSection(title: "Visual characteristics", text: species.visualCharacteristics.joined(separator: " • "))
            if let measurements = species.measurements { DetailSection(title: "Size / measurements", text: Self.measurementsText(measurements)) }
            if let tailShape = species.tailShape, !tailShape.isEmpty { DetailSection(title: "Tail shape", text: tailShape) }
            if !species.mouthAndHeadShape.isEmpty { DetailSection(title: "Head and mouth clues", text: species.mouthAndHeadShape.joined(separator: " • ")) }
            if !species.finAndSpineClues.isEmpty { DetailSection(title: "Fin and spine clues", text: species.finAndSpineClues.joined(separator: " • ")) }
            if !species.appearanceVariants.isEmpty { DetailSection(title: "Life-stage differences", text: species.appearanceVariants.map { $0.description }.joined(separator: " • ")) }
        }
    }

    private var habitat: some View {
        let species = viewModel.species
        return DetailGroup(title: "Habitat and range", isExpanded: $showsHabitat) {
            DetailSection(title: "Typical habitat", text: species.habitat)
            DetailSection(title: "General geographic range", text: species.geographicRange)
            if let occurrence = species.regionalOccurrence { DetailSection(title: "Regional occurrence", text: occurrence.capitalized) }
            if let pack = species.packContext { DetailSection(title: "Dive region", text: pack.displayName) }
        }
    }

    static func taxonomyText(_ taxonomy: SpeciesTaxonomy) -> String {
        [("Accepted name", Optional(taxonomy.acceptedScientificName)), ("Class", taxonomy.taxonomicClass), ("Order", taxonomy.order), ("Family", taxonomy.family), ("Genus", taxonomy.genus)]
            .compactMap { label, value in value.map { "\(label): \($0)" } }.joined(separator: " • ")
    }

    static func measurementsText(_ measurements: SpeciesMeasurements) -> String {
        var parts: [String] = []
        if let minimum = measurements.typicalObservedMinimumCentimeters, let maximum = measurements.typicalObservedMaximumCentimeters { parts.append("Typically \(minimum.formatted())–\(maximum.formatted()) cm") }
        else if let minimum = measurements.typicalObservedMinimumCentimeters { parts.append("Typically from \(minimum.formatted()) cm") }
        else if let maximum = measurements.typicalObservedMaximumCentimeters { parts.append("Typically up to \(maximum.formatted()) cm") }
        if let maximum = measurements.maximumRecordedCentimeters { parts.append("Maximum recorded: \(maximum.formatted()) cm") }
        parts.append(measurements.type.rawValue.replacingOccurrences(of: "Length", with: " length").replacingOccurrences(of: "Width", with: " width").capitalized)
        return parts.joined(separator: " • ")
    }
}

/// A surface card holding one or more detail sections.
private struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.l) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .appCard()
    }
}

/// A collapsible card for reference detail that most sightings do not need at a glance.
private struct DetailGroup<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, AppTheme.Spacing.m)
        } label: {
            Text(title).font(.title3.bold()).foregroundStyle(Color.appTextPrimary)
        }
        .padding()
        .appCard()
    }
}

private struct DetailSection: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(Color.appTextSecondary)
        }
    }
}

/// The source page link and reference that the source licence asks for on each record.
private struct SourceSection: View {
    let sources: [SpeciesDataSourceReference]
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Source").font(.headline)
            ForEach(Array(CatalogueAttribution.sourceLines(for: sources).enumerated()), id: \.offset) { _, line in
                if let url = line.url {
                    Link(line.text, destination: url)
                } else {
                    Text(line.text).foregroundStyle(Color.appTextSecondary)
                }
            }
        }
        .accessibilityIdentifier("speciesSources")
    }
}

/// Who took the photo, under which licence, with links to the photo's page and the licence,
/// as CC BY and CC BY-NC require.
private struct ImageCreditSection: View {
    let image: BundledSpeciesImage

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(image.isPhoto ? "Photo" : "Image credit").font(.headline)
            Text("© \(image.creatorName)").foregroundStyle(Color.appTextSecondary)
            Text("\(image.licenseName) · \(image.sourceName)").font(.subheadline).foregroundStyle(Color.appTextSecondary)
            HStack(spacing: AppTheme.Spacing.l) {
                if let url = URL(string: image.sourceURL) { Link("Photo page", destination: url).font(.subheadline) }
                if let url = URL(string: image.licenseURL) { Link("Licence", destination: url).font(.subheadline) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imageCredit")
    }
}
