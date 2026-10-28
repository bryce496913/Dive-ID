import SwiftUI

/// The field guide's first screen: animal groups with counts and a representative photo,
/// and the ocean-region filter. Fully offline; the catalogue is the one this build exposes.
struct FieldGuideView: View {
    @Bindable var viewModel: FieldGuideViewModel
    let router: AppRouter
    @ScaledMetric(relativeTo: .body) private var thumbnail: CGFloat = 64

    var body: some View {
        Group {
            if let catalogue = viewModel.catalogue {
                List {
                    Section {
                        Picker("Region", selection: $viewModel.region) {
                            ForEach(catalogue.regions) { region in Text(region.title).tag(region) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("fieldGuideRegion")
                        Text("\(viewModel.regionCount.formatted()) species")
                            .font(.subheadline).foregroundStyle(Color.appTextSecondary)
                            .accessibilityIdentifier("fieldGuideRegionCount")
                        if let note = viewModel.unknownDistributionNote {
                            Label(note, systemImage: "info.circle")
                                .font(.footnote).foregroundStyle(Color.appTextSecondary)
                                .accessibilityIdentifier("fieldGuideUnknownNote")
                        }
                    }
                    .listRowBackground(Color.appSurface)
                    Section("Animal groups") {
                        ForEach(viewModel.groups) { group in
                            Button { router.navigate(to: .fieldGuideGroup(id: group.id)) } label: { row(group) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("fieldGuideGroup_\(group.id)")
                        }
                    }
                    .listRowBackground(Color.appSurface)
                }
                .scrollContentBackground(.hidden)
            } else if let error = viewModel.errorMessage {
                ErrorStateView(message: error, retry: { Task { await viewModel.load() } })
            } else {
                LoadingStateView(message: "Opening the field guide…")
            }
        }
        .appScreenBackground()
        .navigationTitle("Field Guide")
        .accessibilityIdentifier("fieldGuide")
        .task { await viewModel.load() }
    }

    private func row(_ group: FieldGuideGroup) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            Group {
                if let species = group.representative {
                    SpeciesArtwork(species: species, showsCaption: false, thumbnailSize: thumbnail)
                } else {
                    // No photographed member: the generic artwork for the group.
                    SpeciesArtwork(species: Species(id: UUID(), commonName: group.title, scientificName: "", summary: "", visualCharacteristics: [],
                                                    habitat: "", geographicRange: "", imageAssetName: nil), showsCaption: false)
                }
            }
            .frame(width: thumbnail, height: thumbnail)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(group.title).font(.headline)
                Text("\(group.count.formatted()) species").font(.subheadline).foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Color.appTextSecondary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.title), \(group.count) species")
        .accessibilityAddTraits(.isButton)
    }
}

/// One group's species, by family: lazily built rows, a local name filter and Has photo.
struct FieldGuideGroupView: View {
    @Bindable var viewModel: FieldGuideViewModel
    let groupID: String
    let router: AppRouter
    @State private var query = ""
    @State private var photosOnly = false
    @ScaledMetric(relativeTo: .body) private var thumbnail: CGFloat = 56

    private var sections: [FieldGuideSection] {
        viewModel.catalogue?.sections(group: groupID, region: viewModel.region, query: query, photosOnly: photosOnly) ?? []
    }

    var body: some View {
        let sections = sections
        List {
            Section {
                Toggle("Has photo", isOn: $photosOnly).accessibilityIdentifier("fieldGuidePhotosOnly")
                Text("\(viewModel.region.title) · \(sections.reduce(0) { $0 + $1.species.count }.formatted()) species")
                    .font(.subheadline).foregroundStyle(Color.appTextSecondary)
                    .accessibilityIdentifier("fieldGuideGroupCount")
                if sections.isEmpty {
                    Text("No species match.").foregroundStyle(Color.appTextSecondary).accessibilityIdentifier("fieldGuideNoMatches")
                }
            }
            .listRowBackground(Color.appSurface)
            ForEach(sections) { section in
                Section(section.family) {
                    // List builds rows lazily, so a 3,000-row group only lays out what is on screen.
                    ForEach(section.species) { species in
                        Button { router.navigate(to: .speciesDetail(species, nil)) } label: { row(species) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("fieldGuideSpecies_\(species.id)")
                    }
                }
                .listRowBackground(Color.appSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .appScreenBackground()
        .navigationTitle(FieldGuideGroup.title(for: groupID))
        .searchable(text: $query, prompt: "Filter by name")
        .task { await viewModel.load() }
    }

    private func row(_ species: Species) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            SpeciesArtwork(species: species, showsCaption: false, thumbnailSize: thumbnail)
                .frame(width: thumbnail, height: thumbnail)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(species.commonName).font(.headline)
                Text(species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(species.commonName), \(species.scientificName), \(species.hasPhoto ? "photo" : "illustration")")
        .accessibilityHint("Opens the species page")
        .accessibilityAddTraits(.isButton)
    }
}
