import Observation
import SwiftUI

@MainActor @Observable
final class HomeViewModel {
    var packState: SelectedPackState = .notLoaded
    private let packLoader: SelectedPackLoader

    init(catalog: any MarineSpeciesCatalogRepository, regionRepository: any SelectedDiveRegionRepository) {
        packLoader = SelectedPackLoader(catalog: catalog, regionRepository: regionRepository)
    }

    func load() async { packState = await packLoader.load() }

    var pack: OfflineIdentificationPackMetadata? { packState.pack }
    var catalogueLoaded: Bool { packState != .notLoaded && packState != .loadFailed }
    var catalogueLoadFailed: Bool { packState == .loadFailed }
    var canSearch: Bool { pack != nil }
    var canChangeRegion: Bool { packState.canChangeRegion }
    var selectedRegionUnavailable: Bool { packState == .selectedRegionUnavailable }
}

struct HomeView: View {
    let router: AppRouter
    let features: FeatureAvailability
    @State var viewModel: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                HomeHeader()
                if let pack = viewModel.pack {
                    Button { router.navigate(to: .offlineRegions) } label: {
                        SelectedPackSummary(pack: pack)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("offlinePackSummary")
                } else {
                    SelectedPackStatusView(
                        state: viewModel.packState,
                        retry: { Task { await viewModel.load() } },
                        changeRegion: { router.navigate(to: .offlineRegions) }
                    )
                }
                FeatureActionCard(
                    title: "Describe What You Saw",
                    subtitle: viewModel.canSearch ? "Use color, shape, size, and habitat clues" : "Unavailable for the selected dive region",
                    symbol: "text.alignleft"
                ) {
                    if viewModel.canSearch { router.navigate(to: .descriptionSearch) }
                }
                .disabled(!viewModel.canSearch)
                .accessibilityIdentifier("describeAction")
                FeatureActionCard(
                    title: "Identify From Photo",
                    subtitle: features.photoIdentificationEnabled ? "Development photo preparation" : "Coming later",
                    symbol: "photo"
                ) {
                    if features.photoIdentificationEnabled { router.navigate(to: .photoIdentification) }
                }
                .disabled(!features.photoIdentificationEnabled)
                .accessibilityHint(features.photoIdentificationEnabled ? "Opens the development photo preparation flow." : "Photo identification is not yet available.")
                .accessibilityIdentifier("photoAction")
                Button { router.navigate(to: .savedIdentifications) } label: {
                    Label("Saved Identifications", systemImage: "bookmark.fill").frame(minHeight: 44)
                }
                .accessibilityIdentifier("savedAction")
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle("Home")
        .task(id: router.path) { await viewModel.load() }
    }
}

private struct HomeHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Image(systemName: "water.waves")
                .font(.system(size: 48))
                .foregroundStyle(Color.appPrimary)
            Text("Dive ID").font(.largeTitle.bold())
            Text("Describe the marine life you saw and review possible matches for your selected dive region.")
                .foregroundStyle(Color.appTextSecondary)
        }
    }
}

private struct SelectedPackSummary: View {
    let pack: OfflineIdentificationPackMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Dive Region").font(.headline)
            Text(pack.displayName).font(.title3.bold())
            Text("\(pack.speciesCount) species available offline for the \(pack.displayName)")
            Text("Included with Dive ID").font(.caption).foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
    }
}

#Preview {
    NavigationStack {
        HomeView(
            router: AppRouter(),
            features: .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: false),
            viewModel: .init(catalog: BundleMarineSpeciesCatalogRepository(), regionRepository: UserDefaultsSelectedDiveRegionRepository())
        )
    }
}
