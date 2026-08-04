import SwiftUI

struct HomeView: View {
    let router: AppRouter
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 24) { VStack(alignment: .leading, spacing: 8) { Image(systemName: "water.waves").font(.system(size: 48)).foregroundStyle(Color.appPrimary); Text("Dive ID").font(.largeTitle.bold()); Text("Describe or photograph the marine life you saw and review the most likely matches.").foregroundStyle(.secondary) }
        FeatureActionCard(title: "Describe What You Saw", subtitle: "Use color, shape, size, and habitat clues", symbol: "text.alignleft") { router.navigate(to: .descriptionSearch) }.accessibilityIdentifier("describeAction")
        FeatureActionCard(title: "Identify From Photo", subtitle: "Choose a photo kept locally on your device", symbol: "photo") { router.navigate(to: .photoIdentification) }.accessibilityIdentifier("photoAction")
        Button { router.navigate(to: .savedSpecies) } label: { Label("Saved Species", systemImage: "bookmark.fill").frame(minHeight: 44) }.accessibilityIdentifier("savedAction")
    }.padding() }.appScreenBackground().navigationTitle("Home") }
}
#Preview { NavigationStack { HomeView(router: AppRouter()) } }
