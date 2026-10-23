import SwiftUI

struct SavedIdentificationsView: View {
    @State var viewModel: SavedSpeciesViewModel
    let router: AppRouter
    /// The sighting the confirmation dialog asks about, from the context menu.
    @State private var confirmingRemoval: SavedIdentification?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            if let error = viewModel.errorMessage {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.appError)
                    Button(AppCopy.tryAgain) { Task { await viewModel.retry() } }
                        .disabled(viewModel.isUpdating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .appCard()
                .padding(.horizontal)
            }
            if viewModel.isLoading {
                LoadingStateView()
            } else if viewModel.identifications.isEmpty {
                if viewModel.errorMessage == nil {
                    EmptyStateView(title: "No saved identifications", message: "Save a possible match to retain why it matched.", systemImage: "bookmark")
                }
            } else {
                List {
                    ForEach(viewModel.identifications) { item in
                        Button { router.navigate(to: .savedIdentification(item)) } label: {
                            HStack(spacing: AppTheme.Spacing.m) {
                                SpeciesArtwork(species: item.species, showsCaption: false)
                                    .frame(width: 58, height: 58)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                    Text(item.species.commonName).font(.headline)
                                    Text(item.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                                    Text("\(item.matchStrength.displayName) · \(item.identifiedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                                    Text(item.explanation.isEmpty ? item.observationDescription : item.explanation)
                                        .lineLimit(2).font(.caption).foregroundStyle(Color.appTextSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.appSurface)
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await viewModel.remove(item) } }
                                .disabled(viewModel.isUpdating)
                        }
                        // Swipe alone is hard to discover, so long-press offers Remove too, behind a confirmation.
                        .contextMenu {
                            Button { router.navigate(to: .savedIdentification(item)) } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
                            Button(role: .destructive) { confirmingRemoval = item } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            .disabled(viewModel.isUpdating)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .appScreenBackground()
        .navigationTitle("Saved Identifications")
        .confirmationDialog(
            "Remove this saved identification?",
            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRemoval
        ) { item in
            Button("Remove \(item.species.commonName)", role: .destructive) { Task { await viewModel.remove(item) } }
        } message: { _ in
            Text("Its saved notes and match details are deleted from this device.")
        }
        .task { await viewModel.load() }
    }
}
