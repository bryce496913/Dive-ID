import SwiftUI

struct PrimaryActionButton: View {
    let title: String; var isLoading = false; var disabled = false; let action: () -> Void
    var body: some View { Button(action: action) { Group { if isLoading { ProgressView().tint(.white) } else { Text(title).fontWeight(.semibold) } }.frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.borderedProminent).tint(.appAccent).disabled(disabled || isLoading) }
}

struct FeatureActionCard: View {
    let title: String; let subtitle: String; let symbol: String; let action: () -> Void
    var body: some View { Button(action: action) { HStack(spacing: 16) { Image(systemName: symbol).font(.title).frame(width: 44, height: 44).background(Color.appAccent.opacity(0.2), in: Circle()); VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(Color.appTextSecondary) }; Spacer(); Image(systemName: "chevron.right") }.padding().foregroundStyle(Color.appTextPrimary).background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }.buttonStyle(.plain) }
}

struct LoadingStateView: View {
    var message = "Loading…"
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, minHeight: 220)
    }
}
struct EmptyStateView: View { let title: String; let message: String; var body: some View { ContentUnavailableView(title, systemImage: "fish", description: Text(message)) } }
struct ErrorStateView: View { let message: String; var retry: (() -> Void)?; var body: some View { ContentUnavailableView { Label("Something went wrong", systemImage: "exclamationmark.triangle") } description: { Text(message) } actions: { if let retry { Button("Try Again", action: retry) } } } }

struct SpeciesArtwork: View {
    let species: Species
    @State private var hasBundledVector = false
    private let loader = BundleSpeciesImageLoader()
    var showsPlaceholder: Bool { species.bundledImage == nil }
    var accessibilityDescription: String { species.bundledImage?.alternativeText ?? "Placeholder image of \(species.commonName)" }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [Color.appAccent.opacity(0.35), Color.appSurface], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: symbolName)
                .font(.system(size: 54, weight: .semibold))
                .foregroundStyle(hasBundledVector ? Color.appHighlight : Color.appTextSecondary)
            VStack { Spacer(); Text(species.commonName).font(.caption.bold()).lineLimit(1).padding(8).frame(maxWidth: .infinity).background(Color.black.opacity(0.35)) }
        }
        .accessibilityLabel(accessibilityDescription)
        .task { if let image = species.bundledImage { hasBundledVector = (try? await loader.imageData(for: image, packID: species.packContext?.packID ?? .caribbean)) != nil } }
    }
    private var symbolName: String {
        if species.commonName.contains("Turtle") { return "tortoise.fill" }
        if species.commonName.contains("Ray") { return "skateboard.fill" }
        if species.commonName.contains("Shark") { return "fish.fill" }
        return "fish.fill"
    }
}

struct SpeciesResultCard: View {
    let match: IdentificationMatch
    var body: some View { HStack(alignment: .top) { SpeciesArtwork(species: match.species).frame(width: 72, height: 72); VStack(alignment: .leading, spacing: 4) { Text("#\(match.rank) · \(match.species.commonName)").font(.headline); if !match.species.scientificName.isEmpty { Text(match.species.scientificName).italic().font(.subheadline) }; Text(match.matchStrength.displayName).font(.caption).foregroundStyle(Color.appTextSecondary); if !match.explanation.isEmpty { Text(match.explanation).font(.subheadline).lineLimit(3) }; ForEach(match.distinguishingFeatures.prefix(2), id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(Color.appTextSecondary) } }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(Color.appTextSecondary) }.padding().foregroundStyle(Color.appTextPrimary).background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }
}
