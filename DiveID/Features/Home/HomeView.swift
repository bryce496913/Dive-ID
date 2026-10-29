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
    func chooseRegion(_ id: OfflineIdentificationPackID) async { packState = await packLoader.choose(id) }

    var pack: OfflineIdentificationPackMetadata? { packState.pack }
    var catalogueLoaded: Bool { packState != .notLoaded && packState != .loadFailed }
    var catalogueLoadFailed: Bool { packState == .loadFailed }
    var canSearch: Bool { pack != nil }
    var canChangeRegion: Bool { packState.canChangeRegion }
    var selectedRegionUnavailable: Bool { packState.isSelectedRegionUnavailable }
}

struct HomeView: View {
    let router: AppRouter
    let features: FeatureAvailability
    @State var viewModel: HomeViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                HomeHero(pack: viewModel.pack) { router.navigate(to: .offlineRegions) }
                if viewModel.pack == nil {
                    SelectedPackStatusView(
                        state: viewModel.packState,
                        retry: { Task { await viewModel.load() } },
                        changeRegion: { router.navigate(to: .offlineRegions) },
                        chooseRegion: { id in Task { await viewModel.chooseRegion(id) } }
                    )
                }
                // The main task leads; photo and the secondary screens follow.
                HomePrimaryTile(
                    title: "Describe What You Saw",
                    subtitle: viewModel.canSearch ? "Use color, shape, size, and habitat clues" : "Unavailable for the selected dive region"
                ) {
                    if viewModel.canSearch { router.navigate(to: .descriptionSearch) }
                }
                .disabled(!viewModel.canSearch)
                .accessibilityIdentifier("describeAction")
                Text("More").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: gridColumns, spacing: AppTheme.Spacing.m) {
                    HomeTile(
                        title: "Identify From Photo",
                        subtitle: features.photoIdentificationEnabled ? "Development build · test recognizer" : "Coming later",
                        symbol: "camera.fill"
                    ) {
                        if features.photoIdentificationEnabled { router.navigate(to: .photoIdentification) }
                    }
                    .disabled(!features.photoIdentificationEnabled)
                    .accessibilityHint(features.photoIdentificationEnabled ? "Opens photo identification. Development builds only." : "Photo identification is not yet available.")
                    .accessibilityIdentifier("photoAction")
                    HomeTile(title: "Dive Log", subtitle: "Your dives and sightings", symbol: "book.fill") {
                        router.navigate(to: .savedIdentifications)
                    }
                    .accessibilityIdentifier("savedAction")
                }
                HomeLinkRow(title: "Field Guide", symbol: "book.closed.fill") { router.navigate(to: .fieldGuide) }
                    .accessibilityIdentifier("fieldGuideAction")
                    .appCard()
                HomeLinkRow(title: "Browse All Species", symbol: "list.bullet.rectangle") {
                    if viewModel.canSearch { router.navigate(to: .speciesCatalogue) }
                }
                .disabled(!viewModel.canSearch)
                .accessibilityIdentifier("browseAction")
                .appCard()
                HomeLinkRow(title: "Data Sources and Credits", symbol: "info.circle") { router.navigate(to: .credits) }
                    .accessibilityIdentifier("creditsAction")
                    .appCard()
            }
            .padding()
        }
        .appScreenBackground()
        .navigationTitle("Home")
        // The hero already names the app; the title stays for the back button on pushed screens.
        .toolbar(.hidden, for: .navigationBar)
        .task(id: router.path) { await viewModel.load() }
    }

    /// Two tiles side by side, or one per row at accessibility text sizes.
    private var gridColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.m, alignment: .top), count: count)
    }
}

/// The brand banner: app name, what it does, and the selected dive region.
private struct HomeHero: View {
    let pack: OfflineIdentificationPackMetadata?
    let changeRegion: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var waveSize: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
            Text("Dive ID").font(.largeTitle.bold())
            Text("Describe the marine life you saw and review possible matches for your selected dive region.")
                .font(.subheadline)
                .foregroundStyle(Color.appTextPrimary.opacity(0.9))
            if let pack {
                Button(action: changeRegion) { RegionPill(pack: pack) }
                    .buttonStyle(AppCardButtonStyle())
                    .accessibilityIdentifier("offlinePackSummary")
                    .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.xxl)
        .background {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: AppTheme.heroRadius, style: .continuous).fill(LinearGradient.appBrand)
                Image(systemName: "water.waves")
                    .font(.system(size: waveSize, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .offset(x: 24, y: -18)
                    .accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.heroRadius, style: .continuous))
            .shadow(color: Color.appAccent.opacity(0.45), radius: 24, y: 10)
        }
        .padding(.top, AppTheme.Spacing.s)
    }
}

/// The selected dive region inside the hero, with a cue that it opens region selection.
private struct RegionPill: View {
    let pack: OfflineIdentificationPackMetadata
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The Change cue moves below the region at accessibility sizes, so the region text keeps the full width.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.s))
            : AnyLayout(HStackLayout(spacing: AppTheme.Spacing.m))
    }

    var body: some View {
        layout {
            if !dynamicTypeSize.isAccessibilitySize { Image(systemName: "map.fill").accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 2) {
                Text("Dive Region").font(.caption.weight(.semibold)).foregroundStyle(Color.appTextPrimary.opacity(0.85))
                Text(pack.displayName).font(.headline)
                Text("\(pack.speciesCount) species available offline for the \(pack.displayName)")
                    .font(.caption).foregroundStyle(Color.appTextPrimary.opacity(0.85))
                Text("Included with Dive ID").font(.caption2).foregroundStyle(Color.appTextPrimary.opacity(0.85))
            }
            .multilineTextAlignment(.leading)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: AppTheme.Spacing.s) }
            HStack(spacing: AppTheme.Spacing.s) {
                Text("Change").font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.appTextPrimary)
        .padding(AppTheme.Spacing.m)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
    }
}

/// Home's main action: a large tile with a call to action.
private struct HomePrimaryTile: View {
    let title: String
    let subtitle: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .title) private var badgeSize: CGFloat = 56

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                Image(systemName: "text.bubble.fill")
                    .font(.title)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(LinearGradient.appBrand, in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(title).font(.title2.bold())
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.appTextSecondary)
                }
                .multilineTextAlignment(.leading)
                HStack(spacing: AppTheme.Spacing.s) {
                    Text("Start")
                    Image(systemName: "arrow.right").accessibilityHidden(true)
                }
                .font(.headline)
                .padding(.horizontal, AppTheme.Spacing.l)
                .padding(.vertical, AppTheme.Spacing.s)
                .background(LinearGradient.appBrand, in: Capsule())
                .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.Spacing.xl)
            .foregroundStyle(Color.appTextPrimary)
            .appCard(cornerRadius: AppTheme.heroRadius)
            .overlay(RoundedRectangle(cornerRadius: AppTheme.heroRadius, style: .continuous).strokeBorder(LinearGradient.appBrand, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.heroRadius))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(AppCardButtonStyle())
    }
}

/// A square-ish tile in Home's grid of secondary actions.
private struct HomeTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 44

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.m) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color.appAccent.opacity(0.22), in: RoundedRectangle(cornerRadius: AppTheme.controlRadius, style: .continuous))
                    .foregroundStyle(Color.appAccent)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(Color.appTextSecondary)
                }
                .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .leading)
            .padding(AppTheme.Spacing.l)
            .foregroundStyle(Color.appTextPrimary)
            .appCard()
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.radius))
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(AppCardButtonStyle())
    }
}

/// A full-width row for a secondary screen.
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
        .buttonStyle(AppCardButtonStyle())
        .foregroundStyle(Color.appTextPrimary)
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
