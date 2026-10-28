import SwiftUI

/// Every species in the selected dive region, with its photo, names and first
/// distinguishing feature; tapping one opens its species page.
struct SpeciesCatalogueView: View {
    @State var viewModel: SpeciesCatalogueViewModel
    let router: AppRouter

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.species.isEmpty {
                LoadingStateView(message: "Loading species…")
            } else if let error = viewModel.errorMessage {
                VStack(spacing: AppTheme.Spacing.m) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                    Button(AppCopy.tryAgain) { Task { await viewModel.load() } }
                }
                .padding()
            } else if viewModel.pack == nil {
                EmptyStateView(title: "No dive region", message: "Choose a dive region to browse its species.", systemImage: "map")
            } else {
                list
            }
        }
        .appScreenBackground()
        .navigationTitle("All Species")
        .searchable(text: $viewModel.searchText, prompt: "Filter by name")
        .task { if viewModel.species.isEmpty { await viewModel.load() } }
    }

    private var list: some View {
        List {
            Section {
                ForEach(viewModel.visibleSpecies) { species in
                    Button { router.navigate(to: .speciesDetail(species, nil)) } label: { row(species) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.appSurface)
                }
            } header: {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    if let pack = viewModel.pack {
                        Text("\(pack.displayName): \(viewModel.species.count) species, \(viewModel.photoCount) with a photo")
                            .font(.subheadline)
                    }
                    Toggle("Only species with a photo", isOn: $viewModel.photosOnly)
                        .font(.subheadline)
                        .accessibilityIdentifier("photosOnly")
                    if viewModel.visibleSpecies.isEmpty {
                        Text("No species match this filter.").font(.subheadline).foregroundStyle(Color.appTextSecondary)
                    }
                }
                .textCase(nil)
                .foregroundStyle(Color.appTextPrimary)
                .padding(.bottom, AppTheme.Spacing.xs)
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("speciesCatalogue")
    }

    private func row(_ species: Species) -> some View {
        HStack(spacing: AppTheme.Spacing.m) {
            SpeciesArtwork(species: species, showsCaption: false)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(species.commonName).font(.headline)
                Text(species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                if let feature = species.visualCharacteristics.first {
                    Text(feature).lineLimit(2).font(.caption).foregroundStyle(Color.appTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(species.hasPhoto ? "Has a photo. Opens the species page." : "Opens the species page.")
    }
}
