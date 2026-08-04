import SwiftUI

struct PrimaryActionButton: View {
    let title: String; var isLoading = false; var disabled = false; let action: () -> Void
    var body: some View { Button(action: action) { Group { if isLoading { ProgressView().tint(.white) } else { Text(title).fontWeight(.semibold) } }.frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(.borderedProminent).tint(.appAccent).disabled(disabled || isLoading) }
}

struct FeatureActionCard: View {
    let title: String; let subtitle: String; let symbol: String; let action: () -> Void
    var body: some View { Button(action: action) { HStack(spacing: 16) { Image(systemName: symbol).font(.title).frame(width: 44, height: 44).background(Color.appAccent.opacity(0.2), in: Circle()); VStack(alignment: .leading) { Text(title).font(.headline); Text(subtitle).font(.subheadline).foregroundStyle(Color.appTextSecondary) }; Spacer(); Image(systemName: "chevron.right") }.padding().foregroundStyle(Color.appTextPrimary).background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }.buttonStyle(.plain) }
}

struct LoadingStateView: View { var body: some View { VStack(spacing: 12) { ProgressView(); Text("Preparing demo matches…").foregroundStyle(.secondary) }.frame(maxWidth: .infinity, minHeight: 220) } }
struct EmptyStateView: View { let title: String; let message: String; var body: some View { ContentUnavailableView(title, systemImage: "fish", description: Text(message)) } }
struct ErrorStateView: View { let message: String; var retry: (() -> Void)?; var body: some View { ContentUnavailableView { Label("Something went wrong", systemImage: "exclamationmark.triangle") } description: { Text(message) } actions: { if let retry { Button("Try Again", action: retry) } } } }

struct SpeciesArtwork: View {
    let species: Species
    var body: some View { ZStack { RoundedRectangle(cornerRadius: 14).fill(Color.appAccent.opacity(0.2)); Image(systemName: species.commonName.contains("Turtle") ? "tortoise.fill" : "fish.fill").font(.largeTitle).foregroundStyle(Color.appHighlight) }.accessibilityLabel("Placeholder image of \(species.commonName)") }
}

struct SpeciesResultCard: View {
    let match: IdentificationMatch
    var body: some View { HStack { SpeciesArtwork(species: match.species).frame(width: 72, height: 72); VStack(alignment: .leading, spacing: 4) { Text(match.species.commonName).font(.headline); Text(match.species.scientificName).italic().font(.subheadline); Text(match.matchStrength.rawValue).font(.caption).foregroundStyle(Color.appTextSecondary) }; Spacer(); Image(systemName: "chevron.right").foregroundStyle(Color.appTextSecondary) }.padding().foregroundStyle(Color.appTextPrimary).background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius)) }
}
