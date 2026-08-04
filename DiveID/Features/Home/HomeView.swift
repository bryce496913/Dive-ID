import SwiftUI

struct HomeView: View {
    let router: AppRouter
    let features: FeatureAvailability
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 24) { VStack(alignment: .leading, spacing: 8) { Image(systemName: "water.waves").font(.system(size: 48)).foregroundStyle(Color.appPrimary); Text("Dive ID").font(.largeTitle.bold()); Text("Describe or photograph the marine life you saw and review the most likely matches.").foregroundStyle(.secondary) }
        FeatureActionCard(title: "Describe What You Saw", subtitle: "Use color, shape, size, and habitat clues", symbol: "text.alignleft") { router.navigate(to: .descriptionSearch) }.accessibilityIdentifier("describeAction")
        FeatureActionCard(title: "Identify From Photo", subtitle: features.photoIdentificationEnabled ? "Mock-only development flow" : "Coming later", symbol: "photo") { if features.photoIdentificationEnabled { router.navigate(to: .photoIdentification) } }
            .disabled(!features.photoIdentificationEnabled)
            .accessibilityHint(features.photoIdentificationEnabled ? "Opens the mock photo identification flow." : "Photo identification is not yet available.")
            .accessibilityIdentifier("photoAction")
        Button { router.navigate(to: .savedSpecies) } label: { Label("Saved Identifications", systemImage: "bookmark.fill").frame(minHeight: 44) }.accessibilityIdentifier("savedAction")
    }.padding() }.appScreenBackground().navigationTitle("Home") }
}
#Preview { NavigationStack { HomeView(router: AppRouter(), features: .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: false)) } }
