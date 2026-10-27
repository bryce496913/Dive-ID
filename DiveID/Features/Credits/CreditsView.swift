import SwiftUI

/// Catalogue-level credits and licence notice for FishBase and SeaLifeBase content, and a
/// credit for every species photo in the packs this build offers.
struct CreditsView: View {
    let catalog: any MarineSpeciesCatalogRepository
    @State private var photoCredits: [PhotoCredit] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                ForEach(CatalogueAttribution.credits, id: \.name) { credit in
                    CreditsCard {
                        Text(credit.name).font(.headline)
                        Text(credit.citation).foregroundStyle(Color.appTextSecondary)
                        Text("Data release \(credit.release)").font(.caption).foregroundStyle(Color.appTextSecondary)
                        if let url = URL(string: credit.websiteURL) { CreditsLink(text: credit.websiteURL, url: url) }
                    }
                }
                CreditsCard {
                    Text("Licence").font(.headline)
                    Text(CatalogueAttribution.licenseNotice).foregroundStyle(Color.appTextSecondary)
                    if let url = URL(string: CatalogueAttribution.licenseURL) { CreditsLink(text: CatalogueAttribution.licenseURL, url: url) }
                }
                CreditsCard {
                    Text("Changes and sources").font(.headline)
                    Text(CatalogueAttribution.modificationNotice).foregroundStyle(Color.appTextSecondary)
                    Text(CatalogueAttribution.perRecordNotice).foregroundStyle(Color.appTextSecondary)
                }
                if !photoCredits.isEmpty {
                    CreditsCard {
                        Text("Species photos").font(.headline)
                        Text(CatalogueAttribution.photoNotice).foregroundStyle(Color.appTextSecondary)
                        ForEach(photoCredits, id: \.image.fileName) { credit in
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(credit.commonName).font(.subheadline.bold())
                                Text(credit.image.creditLine).font(.subheadline).foregroundStyle(Color.appTextSecondary)
                                if let url = URL(string: credit.image.sourceURL) { CreditsLink(text: "Photo page", url: url) }
                            }
                            .padding(.top, AppTheme.Spacing.s)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .accessibilityIdentifier("photoCredits")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appScreenBackground()
        .navigationTitle("Data Sources and Credits")
        .accessibilityIdentifier("creditsScreen")
        .task { await loadPhotoCredits() }
    }

    /// A pack that fails to load contributes no credits; it also shows no photos.
    private func loadPhotoCredits() async {
        guard let metadata = try? await catalog.availablePacks() else { return }
        var packs: [OfflineIdentificationPack] = []
        for pack in metadata {
            if let loaded = try? await catalog.loadPack(id: pack.id) { packs.append(loaded) }
        }
        photoCredits = CatalogueAttribution.photoCredits(in: packs)
    }
}

private struct CreditsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .appCard()
    }
}

/// An external link marked as leaving the app.
private struct CreditsLink: View {
    let text: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label(text, systemImage: "arrow.up.right.square").font(.subheadline)
        }
        .padding(.top, AppTheme.Spacing.xxs)
    }
}
