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
                    // Wraps rather than truncating at large text sizes; the button grows to fit.
                    Text(title).fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, AppTheme.Spacing.s)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(AppPrimaryButtonStyle())
        .disabled(disabled || isLoading)
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
    var chooseRegion: (OfflineIdentificationPackID) -> Void = { _ in }

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
        case .selectedRegionRetired(let recovery):
            EmptyStateView(title: AppCopy.diveRegionUnavailableTitle, message: recovery.message)
            if let suggestion = recovery.suggestion {
                Button { chooseRegion(suggestion.id) } label: {
                    Label(AppCopy.useSuggestedDiveRegion(suggestion.displayName), systemImage: "checkmark.circle.fill").frame(minHeight: 44)
                }
                .accessibilityIdentifier("useSuggestedRegionAction")
            }
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

/// The species' approved photo when one is bundled, otherwise a placeholder. Photos reach
/// the pack only once approved in photo review, so whatever loads here may be shown.
struct SpeciesArtwork: View {
    let species: Species
    /// Thumbnails sit next to the name already, so they leave the name caption off.
    var showsCaption = true
    var loader: any SpeciesImageLoading = BundleSpeciesImageLoader.shared
    /// Set for list rows: the photo is decoded at this size (points) and cached, not decoded
    /// full-size each time the row appears.
    var thumbnailSize: CGFloat? = nil
    @Environment(\.displayScale) private var displayScale
    @State private var photo: UIImage?

    private var bundledPhoto: BundledSpeciesImage? { species.bundledImage.flatMap { $0.isPhoto ? $0 : nil } }
    var showsPlaceholder: Bool { photo == nil }
    var accessibilityDescription: String {
        if photo != nil, let image = bundledPhoto { return image.alternativeText }
        return "Species artwork unavailable"
    }

    var body: some View {
        ZStack {
            if let photo {
                Color.appSurface
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholder
            }
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .task(id: bundledPhoto?.fileName) { await loadPhoto() }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [Color.appAccentDeep.opacity(0.9), Color.appHighlightDeep.opacity(0.55), Color.appSurface], startPoint: .topLeading, endPoint: .bottomTrailing))
            // Sized to the artwork's frame, so the symbol fits a thumbnail as well as the detail header.
            Image(systemName: symbolName)
                .resizable()
                .scaledToFit()
                .fontWeight(.semibold)
                .foregroundStyle(Color.appTextPrimary.opacity(0.85))
                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                .frame(maxWidth: 72, maxHeight: 72)
                .padding(showsCaption ? AppTheme.Spacing.xxl : AppTheme.Spacing.m)
        }
    }

    /// A missing or unreadable file keeps the placeholder; the pack validated it at load.
    private func loadPhoto() async {
        guard let image = bundledPhoto else { photo = nil; return }
        let packID = species.packContext?.packID ?? .global
        if let thumbnailSize {
            let decoded = await SpeciesThumbnailCache.shared.thumbnail(for: image, packID: packID, maxPixelSize: Int((thumbnailSize * displayScale).rounded(.up)))
            guard !Task.isCancelled else { return }
            photo = decoded
            return
        }
        let data = try? await loader.imageData(for: image, packID: packID)
        guard !Task.isCancelled else { return }
        photo = data.flatMap(UIImage.init(data:))
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

/// A possible match in the results list. The first match gets a spotlight layout with a larger
/// thumbnail and a brand-gradient edge; it is still labelled with its rank and strength only.
struct SpeciesResultCard: View {
    let match: IdentificationMatch
    @ScaledMetric(relativeTo: .headline) private var artworkSize: CGFloat = 72
    @ScaledMetric(relativeTo: .headline) private var spotlightArtworkSize: CGFloat = 96

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isSpotlight: Bool { match.rank == 1 }

    /// Side by side, or the artwork above the text at accessibility sizes, where the scaled
    /// thumbnail would otherwise leave the text only a sliver of the row.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.m))
            : AnyLayout(HStackLayout(alignment: .top, spacing: AppTheme.Spacing.m))
    }

    var body: some View {
        layout {
            ZStack(alignment: .topLeading) {
                SpeciesArtwork(species: match.species, showsCaption: false)
                    .frame(width: isSpotlight ? spotlightArtworkSize : artworkSize, height: isSpotlight ? spotlightArtworkSize : artworkSize)
                RankBadge(rank: match.rank).offset(x: -6, y: -6)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("#\(match.rank) · \(match.species.commonName)").font(isSpotlight ? .title3.bold() : .headline)
                if !match.species.scientificName.isEmpty {
                    Text(match.species.scientificName).italic().font(.subheadline).foregroundStyle(Color.appTextSecondary)
                }
                MatchStrengthBadge(strength: match.matchStrength)
                if !match.explanation.isEmpty {
                    Text(match.explanation).font(.subheadline).lineLimit(isSpotlight ? 4 : 3)
                }
                ForEach(match.distinguishingFeatures.prefix(2), id: \.self) { feature in
                    Label(feature, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Color.appTextSecondary)
                        .labelStyle(CompactLabelStyle())
                }
            }
            .multilineTextAlignment(.leading)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: AppTheme.Spacing.s)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.appTextSecondary)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isSpotlight ? AppTheme.Spacing.xl : AppTheme.Spacing.l)
        .foregroundStyle(Color.appTextPrimary)
        .appCard()
        .overlay {
            if isSpotlight {
                RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous).strokeBorder(LinearGradient.appBrand, lineWidth: 2)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.radius))
    }
}

/// The rank number on a result's thumbnail.
private struct RankBadge: View {
    let rank: Int
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 26

    var body: some View {
        Text("\(rank)")
            .font(.caption.bold())
            .monospacedDigit()
            .frame(minWidth: size, minHeight: size)
            .background(LinearGradient.appBrand, in: Circle())
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 2))
            .foregroundStyle(Color.appTextPrimary)
    }
}

/// An icon and text with tight spacing, aligned to the text's first line.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xs) {
            configuration.icon
            configuration.title
        }
    }
}
