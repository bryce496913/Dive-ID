import SwiftUI

/// Catalogue-level credits and licence notice for FishBase and SeaLifeBase content.
struct CreditsView: View {
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
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appScreenBackground()
        .navigationTitle("Data Sources and Credits")
        .accessibilityIdentifier("creditsScreen")
    }
}

private struct CreditsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
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
