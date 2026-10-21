import Observation
import SwiftUI

@MainActor @Observable
final class OfflineRegionsViewModel {
    var packs: [OfflineIdentificationPackMetadata] = []
    var selected: OfflineIdentificationPackID = .caribbean
    var errorMessage: String?
    private let catalog: any MarineSpeciesCatalogRepository
    private let selection: any SelectedDiveRegionRepository

    init(catalog: any MarineSpeciesCatalogRepository, selection: any SelectedDiveRegionRepository) {
        self.catalog = catalog
        self.selection = selection
    }

    func load() async {
        errorMessage = nil
        do {
            selected = await selection.selectedRegion()
            packs = try await catalog.availablePacks()
        } catch {
            packs = []
            errorMessage = AppCopy.diveRegionsLoadFailed
        }
    }

    @discardableResult
    func select(_ id: OfflineIdentificationPackID) async -> Bool {
        guard packs.contains(where: { $0.id == id }) else { return false }
        await selection.setSelectedRegion(id)
        selected = id
        return true
    }
}

struct OfflineRegionsView: View {
    @State var viewModel: OfflineRegionsViewModel
    var selectionDidChange: () -> Void = {}

    var body: some View {
        List {
            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(Color.appError)
                    .listRowBackground(Color.appSurface)
            }
            if viewModel.packs.isEmpty && viewModel.errorMessage == nil {
                EmptyStateView(title: AppCopy.noReviewedCatalogueTitle, message: AppCopy.noReviewedCatalogueMessage)
                    .listRowBackground(Color.appSurface)
            }
            ForEach(viewModel.packs) { pack in
                Button {
                    Task { if await viewModel.select(pack.id) { selectionDidChange() } }
                } label: {
                    RegionRow(pack: pack, isSelected: viewModel.selected == pack.id)
                }
                .accessibilityIdentifier("region_\(pack.id.rawValue)")
                .listRowBackground(Color.appSurface)
            }
            Text("Development builds can expose explicitly selected experimental catalogues. Release catalogues list only records backed by human-review evidence and never substitute another region.")
                .font(.footnote)
                .foregroundStyle(Color.appTextSecondary)
                .listRowBackground(Color.appSurface)
        }
        .appScreenBackground()
        .navigationTitle("Dive Region")
        .task { await viewModel.load() }
    }
}

private struct RegionRow: View {
    let pack: OfflineIdentificationPackMetadata
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            HStack {
                Text(pack.displayName).font(.headline)
                Spacer()
                if isSelected { Label("Selected", systemImage: "checkmark.circle.fill") }
            }
            Text("\(pack.speciesCount) species available offline")
            Label(pack.publicationStatusText, systemImage: pack.isExperimental ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(pack.isExperimental ? Color.appWarning : Color.appTextPrimary)
            Text("Catalogue version \(pack.packVersion)")
            Text(pack.geographicScope).font(.caption).foregroundStyle(Color.appTextSecondary)
        }
        .foregroundStyle(Color.appTextPrimary)
    }
}
