import Observation
import SwiftUI

@MainActor @Observable
final class OfflineRegionsViewModel {
    var packs: [OfflineIdentificationPackMetadata] = []
    var selected: OfflineIdentificationPackID = .caribbean
    var errorMessage: String?
    private let catalog: any MarineSpeciesCatalogRepository
    private let selection: any SelectedDiveRegionRepository
    init(catalog: any MarineSpeciesCatalogRepository, selection: any SelectedDiveRegionRepository) { self.catalog = catalog; self.selection = selection }
    func load() async { do { selected = await selection.selectedRegion(); packs = try await catalog.availablePacks() } catch { errorMessage = "Offline regions could not be loaded." } }
    func select(_ id: OfflineIdentificationPackID) async { await selection.setSelectedRegion(id); selected = id }
}

struct OfflineRegionsView: View {
    @State var viewModel: OfflineRegionsViewModel
    var body: some View { List { if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.appError) }
        if viewModel.packs.isEmpty && viewModel.errorMessage == nil { EmptyStateView(title: "No reviewed catalogue available", message: "No human-reviewed identification catalogue is currently available for new searches. Saved identifications remain available from Home.") }
        ForEach(viewModel.packs) { pack in Button { Task { await viewModel.select(pack.id) } } label: { VStack(alignment: .leading, spacing: 8) { HStack { Text(pack.displayName).font(.headline); Spacer(); if viewModel.selected == pack.id { Label("Selected", systemImage: "checkmark.circle.fill") } } ; Text("\(pack.speciesCount) species available offline"); Label(pack.publicationStatusText, systemImage: pack.isExperimental ? "exclamationmark.triangle.fill" : "checkmark.seal.fill").foregroundStyle(pack.isExperimental ? Color.appWarning : Color.appTextPrimary); Text("Pack version \(pack.packVersion)"); Text(pack.geographicScope).font(.caption).foregroundStyle(.secondary) }.foregroundStyle(Color.appTextPrimary) } }
        Text("Development builds can expose explicitly selected experimental packs. Release catalogues list only records backed by human-review evidence and never substitute another region.").font(.footnote).foregroundStyle(.secondary)
    }.navigationTitle("Offline Dive Region").task { await viewModel.load() } }
}
