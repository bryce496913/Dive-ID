import Observation
import SwiftUI

@MainActor @Observable final class IdentificationResultsViewModel {
    let source: IdentificationSource; var state: LoadState<[IdentificationMatch]> = .idle
    private let service: any MarineLifeIdentificationService
    init(source: IdentificationSource, service: any MarineLifeIdentificationService) { self.source = source; self.service = service }
    func load() async { state = .loading; do { let matches = try await (source == .photo ? service.identify(from: Data([1])) : service.identify(from: description)); state = matches.isEmpty ? .empty : .loaded(Array(matches.sorted { $0.confidence > $1.confidence }.prefix(10))) } catch is CancellationError { } catch { state = .failed("Demo matches could not be loaded. Please try again.") } }
    private var description: String { if case .description(let text) = source { text } else { "" } }
}

struct IdentificationResultsView: View {
    @State var viewModel: IdentificationResultsViewModel; let router: AppRouter
    var body: some View { Group { switch viewModel.state { case .idle, .loading: LoadingStateView(); case .empty: EmptyStateView(title: "No demo matches", message: "Try adding more visual details or using another photo."); case .failed(let message): ErrorStateView(message: message) { Task { await viewModel.load() } }; case .loaded(let matches): ScrollView { LazyVStack(spacing: 12) { Text("Confidence values are demonstration data, not measured identification certainty.").font(.footnote).foregroundStyle(.secondary); ForEach(matches) { match in Button { router.navigate(to: .speciesDetail(match.species, match.confidence)) } label: { SpeciesResultCard(match: match) }.buttonStyle(.plain).accessibilityIdentifier("result_\(match.species.id)") }; Text("Identification suggestions may be inaccurate. Confirm important sightings with a qualified local guide or trusted reference.").font(.footnote).foregroundStyle(.secondary).padding(.top) }.padding() } } }.background(Color.appBackground).navigationTitle("Possible Matches").task { if case .idle = viewModel.state { await viewModel.load() } } }
}
