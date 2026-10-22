import SwiftUI

/// Catalogue-level credits and licence notice for FishBase and SeaLifeBase content.
struct CreditsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                ForEach(CatalogueAttribution.credits, id: \.name) { credit in
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(credit.name).font(.headline)
                        Text(credit.citation).foregroundStyle(Color.appTextSecondary)
                        Text("Data release \(credit.release)").font(.caption).foregroundStyle(Color.appTextSecondary)
                        if let url = URL(string: credit.websiteURL) { Link(credit.websiteURL, destination: url) }
                    }
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Licence").font(.headline)
                    Text(CatalogueAttribution.licenseNotice).foregroundStyle(Color.appTextSecondary)
                    if let url = URL(string: CatalogueAttribution.licenseURL) { Link(CatalogueAttribution.licenseURL, destination: url) }
                }
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
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
