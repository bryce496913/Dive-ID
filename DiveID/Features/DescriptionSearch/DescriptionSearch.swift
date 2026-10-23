import Observation
import SwiftUI

@MainActor @Observable
final class DescriptionSearchViewModel {
    var descriptionText = ""
    var isCreatingSession = false
    var errorMessage: String?
    var packState: SelectedPackState = .notLoaded
    private let sessionStore: any IdentificationSessionStore
    private let packLoader: SelectedPackLoader
#if DEBUG || DIVEID_INTERNAL
    let diagnostics = InternalSearchDiagnostics.shared
#endif

    init(sessionStore: any IdentificationSessionStore, catalog: any MarineSpeciesCatalogRepository, regionRepository: any SelectedDiveRegionRepository) { self.sessionStore = sessionStore; packLoader = SelectedPackLoader(catalog: catalog, regionRepository: regionRepository) }

    /// Loads the selected pack's metadata, then starts preparing its search index in the
    /// background (off the main thread), so the first search usually finds it ready.
    func load() async {
        packState = await packLoader.load()
        guard let pack else { return }
#if DEBUG || DIVEID_INTERNAL
        SearchIndexPreparation.start(packID: pack.id, catalog: packLoader.catalog, diagnostics: diagnostics)
#else
        SearchIndexPreparation.start(packID: pack.id, catalog: packLoader.catalog)
#endif
    }

    var pack: OfflineIdentificationPackMetadata? { packState.pack }
    var normalizedDescription: String { descriptionText.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Trimmed description lengths that can be searched.
    nonisolated static let descriptionLengthRange = 3...2000
    var canSubmit: Bool { pack != nil && Self.descriptionLengthRange.contains(normalizedDescription.count) && !isCreatingSession }

    func submit() async -> UUID? {
        guard canSubmit, let pack else { return nil }
        isCreatingSession = true
        errorMessage = nil
        defer { isCreatingSession = false }
        do {
            let request = IdentificationRequest(source: .description(normalizedDescription), context: IdentificationContext(region: pack.id))
            return try await sessionStore.createSession(for: request, photo: nil)
        } catch IdentificationSessionStoreError.capacityReached {
            errorMessage = AppCopy.sessionCapacityReached
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            errorMessage = "The identification session could not be created. Please try again."
            return nil
        }
    }
}

struct DescriptionSearchView: View {
    @State var viewModel: DescriptionSearchViewModel
    let router: AppRouter
    @FocusState private var isEditorFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The Change button moves below the region at accessibility sizes, so the region text keeps the full width.
    private var regionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AppTheme.Spacing.s))
            : AnyLayout(HStackLayout(spacing: AppTheme.Spacing.m))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.l) {
                    ClueGuide()
                    if let pack = viewModel.pack {
                        regionLayout {
                            if !dynamicTypeSize.isAccessibilitySize {
                                Image(systemName: "map.fill").foregroundStyle(Color.appAccent).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text("Dive region: \(pack.displayName)").font(.headline)
                                Text("\(pack.speciesCount) species available offline").font(.subheadline).foregroundStyle(Color.appTextSecondary)
                            }
                            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: AppTheme.Spacing.s) }
                            Button("Change") { router.navigate(to: .offlineRegions) }.fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .appCard()
                    }
                    else { SelectedPackStatusView(state: viewModel.packState, retry: { Task { await viewModel.load() } }, changeRegion: { router.navigate(to: .offlineRegions) }) }
                    ZStack(alignment: .topLeading) {
                        if viewModel.descriptionText.isEmpty {
                            Text("Example: Small blue fish, approximately 20 cm, seen on a shallow reef in the selected region.")
                                .foregroundStyle(Color.appTextSecondary.opacity(0.7)).padding(AppTheme.Spacing.m)
                        }
                        TextEditor(text: $viewModel.descriptionText)
                            .frame(minHeight: 190).scrollContentBackground(.hidden).padding(AppTheme.Spacing.xs)
                            .focused($isEditorFocused)
                            .accessibilityIdentifier("descriptionText")
                    }
                    .appCard()
                    // The editor's edge lights up with the brand gradient while typing.
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
                            .strokeBorder(LinearGradient.appBrand, lineWidth: 2)
                            .opacity(isEditorFocused ? 1 : 0)
                            .animation(.easeOut(duration: 0.2), value: isEditorFocused)
                            .allowsHitTesting(false)
                    }
                    DescriptionLengthHint(count: viewModel.normalizedDescription.count)
                    if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.appError) }
                    findMatchesButton.id(Self.findMatchesAnchor)
                    Label("Processed on this device. Results cover only the species included with this version of Dive ID.", systemImage: "iphone")
                        .font(.footnote).foregroundStyle(Color.appTextSecondary)
#if DEBUG || DIVEID_INTERNAL
                    // Below the search controls, so it never moves or covers them.
                    if let pack = viewModel.pack { InternalSearchDiagnosticsView(packID: pack.id, diagnostics: viewModel.diagnostics) }
#endif
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            // Find Matches sits right under the editor. Once the keyboard has opened, scroll it into
            // view so it lands just above the keyboard, where one tap dismisses the keyboard and submits.
            .onChange(of: isEditorFocused) { _, isFocused in
                guard isFocused else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation { proxy.scrollTo(Self.findMatchesAnchor, anchor: .bottom) }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isEditorFocused = false }
                    .accessibilityIdentifier("dismissKeyboard")
            }
        }
        .appScreenBackground()
        .navigationTitle("Describe What You Saw")
        .task(id: router.path) { await viewModel.load() }
    }

    private static let findMatchesAnchor = "findMatchesAnchor"

    private var findMatchesButton: some View {
        PrimaryActionButton(title: "Find Matches", isLoading: viewModel.isCreatingSession, disabled: !viewModel.canSubmit) {
            // One tap both dismisses the keyboard and submits.
            isEditorFocused = false
            Task {
#if DEBUG || DIVEID_INTERNAL
                if let pack = viewModel.pack { viewModel.diagnostics.querySubmitted(packID: pack.id) }
#endif
                await router.waitForSessionUpdates()
                if let sessionID = await viewModel.submit() {
                    router.navigate(to: .identificationResults(sessionID: sessionID))
                } else {
#if DEBUG || DIVEID_INTERNAL
                    viewModel.diagnostics.queryFinished(.failed)
#endif
                }
            }
        }
        .accessibilityIdentifier("findMatches")
    }
}

/// The clues worth including, as a row of chips above the editor.
private struct ClueGuide: View {
    private static let clues: [(String, String)] = [
        ("Color", "paintpalette.fill"), ("Size", "ruler.fill"), ("Markings", "circle.dotted"),
        ("Shape", "fish.fill"), ("Behavior", "figure.wave"), ("Habitat", "leaf.fill"),
        ("Depth", "arrow.down.to.line"), ("Where", "map.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.s) {
            Text("Include as many clues as you can").font(.headline)
            FlowLayout(spacing: AppTheme.Spacing.s) {
                ForEach(Self.clues, id: \.0) { clue in
                    Label(clue.0, systemImage: clue.1)
                        .labelStyle(CompactLabelStyle())
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, AppTheme.Spacing.m)
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .background(Color.appAccent.opacity(0.18), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.35), lineWidth: 1))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Include color, size, markings, shape, behavior, habitat, depth, and where you saw it.")
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = chipSize(subviews[index], maxWidth: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = chipSize(subviews[index], maxWidth: maxWidth)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }

    /// A child's natural size, or its size wrapped to the row width when it is wider than a row,
    /// as a chip can be at the largest text sizes.
    private func chipSize(_ subview: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > maxWidth else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }
}

/// Counts the trimmed description against the range `canSubmit` accepts, so a disabled
/// Find Matches explains itself.
private struct DescriptionLengthHint: View {
    let count: Int
    private var range: ClosedRange<Int> { DescriptionSearchViewModel.descriptionLengthRange }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if let hint { Text(hint) }
            Spacer(minLength: AppTheme.Spacing.s)
            Text("\(count.formatted()) / \(range.upperBound.formatted())")
                .monospacedDigit()
                .accessibilityLabel("\(count) of \(range.upperBound) characters")
        }
        .font(.caption)
        .foregroundStyle(count > range.upperBound ? Color.appError : Color.appTextSecondary)
    }

    private var hint: String? {
        if count > range.upperBound { return "Shorten your description to search." }
        if count > 0 && count < range.lowerBound { return "Add a little more detail to search." }
        return nil
    }
}
