import Observation
import Foundation

enum AppRoute: Hashable {
    case descriptionSearch
    case photoIdentification
    case identificationResults(sessionID: UUID)
    case speciesDetail(Species, IdentificationMatch?)
    case savedIdentification(SavedIdentification)
    case savedSpecies
    case offlineRegions
}

@MainActor @Observable
final class AppRouter {
    var path: [AppRoute] = [] {
        didSet { reconcileSessions(previous: oldValue) }
    }
    private let sessionStore: any IdentificationSessionStore
    @ObservationIgnored private var resultsModels: [UUID: IdentificationResultsViewModel] = [:]
    @ObservationIgnored private var sessionUpdateTask: Task<Void, Never>?

    init(sessionStore: any IdentificationSessionStore = InMemoryIdentificationSessionStore()) {
        self.sessionStore = sessionStore
    }

    func navigate(to route: AppRoute) { path.append(route) }
    func goBack() { if !path.isEmpty { path.removeLast() } }

    func resultsModel(sessionID: UUID, service: any MarineLifeIdentificationService,
                      catalog: any MarineSpeciesCatalogRepository) -> IdentificationResultsViewModel {
        if let existing = resultsModels[sessionID] { return existing }
        let model = IdentificationResultsViewModel(sessionID: sessionID, service: service,
                                                   sessionStore: sessionStore, catalog: catalog)
        resultsModels[sessionID] = model
        return model
    }

    private static func sessions(in path: [AppRoute]) -> Set<UUID> {
        Set(path.compactMap { route in
            switch route {
            case .identificationResults(let id): return id
            case .speciesDetail(_, let match): return match?.sourceSessionID
            default: return nil // Persisted sightings do not own temporary sessions.
            }
        })
    }

    private func reconcileSessions(previous: [AppRoute]) {
        let active = Self.sessions(in: path)
        let removed = Self.sessions(in: previous).subtracting(active)
        for id in removed {
            resultsModels.removeValue(forKey: id)?.cancel()
        }
        // Serialize actor updates so fast path edits cannot reorder pin/release work.
        let preceding = sessionUpdateTask
        sessionUpdateTask = Task { [sessionStore] in
            await preceding?.value
            for id in removed { await sessionStore.removeSession(id) }
            await sessionStore.retainSessions(active)
        }
    }

    func waitForSessionUpdates() async { await sessionUpdateTask?.value }
}
