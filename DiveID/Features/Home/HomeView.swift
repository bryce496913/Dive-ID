import Observation
import SwiftUI

@MainActor @Observable
final class HomeViewModel {
    var pack: OfflineIdentificationPackMetadata?
    private let catalog: any MarineSpeciesCatalogRepository
    private let regionRepository: any SelectedDiveRegionRepository
    init(catalog: any MarineSpeciesCatalogRepository, regionRepository: any SelectedDiveRegionRepository) { self.catalog = catalog; self.regionRepository = regionRepository }
    func load() async {
        let selectedID = await regionRepository.selectedRegion()
        pack = try? await catalog.availablePacks().first { $0.id == selectedID }
    }
}

struct HomeView: View {
    let router: AppRouter
    let features: FeatureAvailability
    @State var viewModel: HomeViewModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 24) { VStack(alignment: .leading, spacing: 8) { Image(systemName: "water.waves").font(.system(size: 48)).foregroundStyle(Color.appPrimary); Text("Dive ID").font(.largeTitle.bold()); Text("Describe the marine life you saw and review possible matches from your offline regional pack.").foregroundStyle(.secondary) }
        if let pack = viewModel.pack { Button { router.navigate(to: .offlineRegions) } label: { VStack(alignment: .leading, spacing: 6) { Text("Offline Identification Pack").font(.headline); Text(pack.displayName).font(.title3.bold()); Text("\(pack.speciesCount) species available offline for the \(pack.displayName)"); Text("Included with Dive ID").font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }.buttonStyle(.plain).accessibilityIdentifier("offlinePackSummary") }
        FeatureActionCard(title: "Describe What You Saw", subtitle: "Use color, shape, size, and habitat clues", symbol: "text.alignleft") { router.navigate(to: .descriptionSearch) }.accessibilityIdentifier("describeAction")
        FeatureActionCard(title: "Identify From Photo", subtitle: features.photoIdentificationEnabled ? "Development photo preparation" : "Coming later", symbol: "photo") { if features.photoIdentificationEnabled { router.navigate(to: .photoIdentification) } }.disabled(!features.photoIdentificationEnabled).accessibilityHint(features.photoIdentificationEnabled ? "Opens the development photo preparation flow." : "Photo identification is not yet available.").accessibilityIdentifier("photoAction")
        Button { router.navigate(to: .savedSpecies) } label: { Label("Saved Identifications", systemImage: "bookmark.fill").frame(minHeight: 44) }.accessibilityIdentifier("savedAction")
    }.padding() }.appScreenBackground().navigationTitle("Home").task { await viewModel.load() } }
}
#Preview { NavigationStack { HomeView(router: AppRouter(), features: .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: false), viewModel: .init(catalog: BundleMarineSpeciesCatalogRepository(), regionRepository: UserDefaultsSelectedDiveRegionRepository())) } }
