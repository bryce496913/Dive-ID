import SwiftUI

struct SavedSpeciesView: View {
    @State var viewModel: SavedSpeciesViewModel
    let router: AppRouter

    var body: some View {
        VStack {
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(Color.appError)
                Button("Retry saved storage") { Task { await viewModel.retry() } }
                    .disabled(viewModel.isUpdating)
            }
            if viewModel.isLoading {
                LoadingStateView()
            } else if viewModel.identifications.isEmpty {
                if viewModel.errorMessage == nil {
                    EmptyStateView(title: "No saved identifications", message: "Save a possible match to retain why it matched.")
                }
            } else {
                List {
                    ForEach(viewModel.identifications) { item in
                        Button { router.navigate(to: .savedIdentification(item)) } label: {
                            HStack {
                                SpeciesArtwork(species: item.species).frame(width: 58, height: 58)
                                VStack(alignment: .leading) {
                                    Text(item.species.commonName)
                                    Text(item.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                                    Text("\(item.matchStrength.displayName) · \(item.identifiedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                                    Text(item.explanation.isEmpty ? item.observationDescription : item.explanation)
                                        .lineLimit(2).font(.caption).foregroundStyle(Color.appTextSecondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.appSurface)
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await viewModel.remove(item) } }
                                .disabled(viewModel.isUpdating)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .padding(.horizontal)
        .appScreenBackground()
        .navigationTitle("Saved Identifications")
        .task { await viewModel.load() }
    }
}
