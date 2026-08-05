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
        ForEach(viewModel.packs) { pack in Button { Task { await viewModel.select(pack.id) } } label: { VStack(alignment: .leading, spacing: 8) { HStack { Text(pack.displayName).font(.headline); Spacer(); if viewModel.selected == pack.id { Label("Selected", systemImage: "checkmark.circle.fill") } } ; Text("\(pack.speciesCount) species available offline"); Text("Included with Dive ID"); Text("Pack version \(pack.packVersion)"); Text(pack.geographicScope).font(.caption).foregroundStyle(.secondary) }.foregroundStyle(Color.appTextPrimary) } }
        Text("More regional packs may be added later. The Caribbean pack is included with this version and works without internet access.").font(.footnote).foregroundStyle(.secondary)
    }.navigationTitle("Offline Dive Region").task { await viewModel.load() } }
}
