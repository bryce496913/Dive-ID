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
                // The main task leads; region, photo, and the secondary screens follow.
                FeatureActionCard(
                    title: "Describe What You Saw",
                    subtitle: viewModel.canSearch ? "Use color, shape, size, and habitat clues" : "Unavailable for the selected dive region",
                    symbol: "text.alignleft",
                    isProminent: true
                ) {
                    if viewModel.canSearch { router.navigate(to: .descriptionSearch) }
                }
                .disabled(!viewModel.canSearch)
                .accessibilityIdentifier("describeAction")
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
                    title: "Identify From Photo",
                    subtitle: features.photoIdentificationEnabled ? "Development photo preparation" : "Coming later",
                    symbol: "photo"
                ) {
                    if features.photoIdentificationEnabled { router.navigate(to: .photoIdentification) }
                }
                .disabled(!features.photoIdentificationEnabled)
                .accessibilityHint(features.photoIdentificationEnabled ? "Opens the development photo preparation flow." : "Photo identification is not yet available.")
                .accessibilityIdentifier("photoAction")
                VStack(spacing: 0) {
                    HomeLinkRow(title: "Saved Identifications", symbol: "bookmark.fill") { router.navigate(to: .savedIdentifications) }
                        .accessibilityIdentifier("savedAction")
                    Divider().padding(.leading, AppTheme.Spacing.l)
                    HomeLinkRow(title: "Data Sources and Credits", symbol: "info.circle") { router.navigate(to: .credits) }
                        .accessibilityIdentifier("creditsAction")
                }
                .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle("Home")
        // The header already names the app; the title stays for the back button on pushed screens.
        .toolbar(.hidden, for: .navigationBar)
        .task(id: router.path) { await viewModel.load() }
    }
}

private struct HomeHeader: View {
    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Image(systemName: "water.waves")
                .font(.system(size: symbolSize))
                .foregroundStyle(Color.appPrimary)
                .accessibilityHidden(true)
            Text("Dive ID").font(.largeTitle.bold())
            Text("Describe the marine life you saw and review possible matches for your selected dive region.")
                .foregroundStyle(Color.appTextSecondary)
        }
    }
}

/// A row in Home's grouped list of secondary screens.
private struct HomeLinkRow: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.m) {
                Label(title, systemImage: symbol)
                Spacer(minLength: AppTheme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .padding(.horizontal)
            .padding(.vertical, AppTheme.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.appTextPrimary)
    }
}

private struct SelectedPackSummary: View {
    let pack: OfflineIdentificationPackMetadata

    var body: some View {
        HStack(spacing: AppTheme.Spacing.m) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Dive Region").font(.headline)
                Text(pack.displayName).font(.title3.bold())
                Text("\(pack.speciesCount) species available offline for the \(pack.displayName)")
                Text("Included with Dive ID").font(.caption).foregroundStyle(Color.appTextSecondary)
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            // Says the summary opens region selection; it was tappable with no visual cue.
            Text("Change").font(.subheadline.weight(.semibold)).foregroundStyle(Color.appAccent)
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
            features: .init(photoIdentificationEnabled: false),
            viewModel: .init(catalog: BundleMarineSpeciesCatalogRepository(), regionRepository: UserDefaultsSelectedDiveRegionRepository())
        )
    }
}
