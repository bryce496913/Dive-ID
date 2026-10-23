import SwiftUI

struct PrimaryActionButton: View {
    let title: String
    var isLoading = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().tint(.white)
                } else {
                    Text(title).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: AppTheme.controlRadius))
        .tint(.appAccent)
        .disabled(disabled || isLoading)
    }
}

struct FeatureActionCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    /// Grows the icon badge with Dynamic Type so the symbol never clips.
    @ScaledMetric(relativeTo: .title) private var badgeSize: CGFloat = 44

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.l) {
                Image(systemName: symbol)
                    .font(.title2)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Color.appAccent.opacity(0.2), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(Color.appTextSecondary)
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: AppTheme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
            }
            .padding()
            .foregroundStyle(Color.appTextPrimary)
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.radius))
            // A plain button does not dim its custom colors when disabled, so do it here.
            .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

struct LoadingStateView: View {
    var message = "Loading…"
    var body: some View {
        VStack(spacing: AppTheme.Spacing.m) {
            ProgressView()
            Text(message).foregroundStyle(Color.appTextSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    var systemImage = "fish"

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

struct ErrorStateView: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            if let retry { Button(AppCopy.tryAgain, action: retry) }
        }
    }
}

/// The selected-region states other than a loaded pack, shared by Home and Describe What You Saw.
struct SelectedPackStatusView: View {
    let state: SelectedPackState
    let retry: () -> Void
    let changeRegion: () -> Void

    var body: some View {
        switch state {
        case .loadFailed:
            ErrorStateView(message: AppCopy.catalogueLoadFailed, retry: retry)
        case .selectedRegionUnavailable:
            EmptyStateView(title: AppCopy.diveRegionUnavailableTitle, message: AppCopy.diveRegionUnavailableMessage)
            Button(action: changeRegion) {
                Label("Change Dive Region", systemImage: "map.fill").frame(minHeight: 44)
            }
            .accessibilityIdentifier("changeRegionAction")
        case .noReviewedCatalogue:
            EmptyStateView(title: AppCopy.noReviewedCatalogueTitle, message: AppCopy.noReviewedCatalogueMessage)
        case .notLoaded, .loaded:
            EmptyView()
        }
    }
}

struct SpeciesArtwork: View {
    let species: Species
    /// Thumbnails sit next to the name already, so they leave the name caption off.
    var showsCaption = true
    var showsPlaceholder: Bool { true }
    var accessibilityDescription: String { "Species artwork unavailable" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color.appAccent.opacity(0.35), Color.appSurface], startPoint: .topLeading, endPoint: .bottomTrailing))
            // Sized to the artwork's frame, so the symbol fits a thumbnail as well as the detail header.
            Image(systemName: symbolName)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: 72, maxHeight: 72)
                .padding(showsCaption ? AppTheme.Spacing.xxl : AppTheme.Spacing.m)
            if showsCaption {
                VStack {
                    Spacer()
                    Text(species.commonName)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .padding(AppTheme.Spacing.s)
                        .frame(maxWidth: .infinity)
                        .background(Color.black.opacity(0.35))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .accessibilityLabel(accessibilityDescription)
    }

    private var symbolName: String {
        if species.commonName.contains("Turtle") { return "tortoise.fill" }
        if species.commonName.contains("Shark") { return "fish.fill" }
        return "fish.fill"
    }
}

/// A neutral capsule for a match's strength band. Deliberately uncolored: strength is
/// relative clue similarity, and a traffic-light color would read as confidence.
struct MatchStrengthBadge: View {
    let strength: MatchStrength

    var body: some View {
        Text(strength.displayName)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, AppTheme.Spacing.s)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Color.appAccent.opacity(0.25), in: Capsule())
            .foregroundStyle(Color.appTextPrimary)
    }
}

struct SpeciesResultCard: View {
    let match: IdentificationMatch
    @ScaledMetric(relativeTo: .headline) private var artworkSize: CGFloat = 72

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.m) {
            SpeciesArtwork(species: match.species, showsCaption: false)
                .frame(width: artworkSize, height: artworkSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("#\(match.rank) · \(match.species.commonName)").font(.headline)
                if !match.species.scientificName.isEmpty {
                    Text(match.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                }
                MatchStrengthBadge(strength: match.matchStrength)
                if !match.explanation.isEmpty {
                    Text(match.explanation).font(.subheadline).lineLimit(3)
                }
                ForEach(match.distinguishingFeatures.prefix(2), id: \.self) {
                    Text("• \($0)").font(.caption).foregroundStyle(Color.appTextSecondary)
                }
            }
            .multilineTextAlignment(.leading)
            Spacer(minLength: AppTheme.Spacing.s)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.appTextSecondary)
                .accessibilityHidden(true)
        }
        .padding()
        .foregroundStyle(Color.appTextPrimary)
        .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppTheme.radius))
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.radius))
    }
}
