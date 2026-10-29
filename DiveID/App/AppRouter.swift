import Observation
import Foundation

enum AppRoute: Hashable {
    case descriptionSearch
    case photoIdentification
    case identificationResults(sessionID: UUID)
    case speciesDetail(Species, IdentificationMatch?)
    case savedIdentification(SavedIdentification)
    case savedIdentifications
    case offlineRegions
    case credits
    case speciesCatalogue
    case fieldGuide
    case fieldGuideGroup(id: String)
    case dive(id: UUID)
}

@MainActor @Observable
final class AppRouter {
    var path: [AppRoute] = [] {
        didSet {
            // A disabled feature is never reachable, even by a programmatic push.
            if !features.photoIdentificationEnabled, path.contains(.photoIdentification) {
                path.removeAll { $0 == .photoIdentification }
            }
            reconcileSessions(previous: oldValue)
        }
    }
    let features: FeatureAvailability
    private let sessionStore: any IdentificationSessionStore
    @ObservationIgnored private var resultsModels: [UUID: IdentificationResultsViewModel] = [:]
    @ObservationIgnored private var sessionUpdateTask: Task<Void, Never>?
    /// One field guide per visit, shared by its group screens; dropped when the guide closes.
    @ObservationIgnored private var fieldGuide: FieldGuideViewModel?
    /// One Dive Log per visit, shared by its dive pages; dropped when the log closes.
    @ObservationIgnored private var diveLog: DiveLogViewModel?

    init(sessionStore: any IdentificationSessionStore = InMemoryIdentificationSessionStore(), features: FeatureAvailability = .current) {
        self.sessionStore = sessionStore
        self.features = features
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

    func fieldGuideModel(catalog: any MarineSpeciesCatalogRepository) -> FieldGuideViewModel {
        if let fieldGuide { return fieldGuide }
        let model = FieldGuideViewModel(catalog: catalog)
        fieldGuide = model
        return model
    }

    func diveLogModel(repository: any SavedLogRepository, catalog: any MarineSpeciesCatalogRepository) -> DiveLogViewModel {
        if let diveLog { return diveLog }
        let model = DiveLogViewModel(repository: repository, catalog: catalog)
        diveLog = model
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
        if !path.contains(.fieldGuide) { fieldGuide = nil }
        if !path.contains(.savedIdentifications) { diveLog = nil }
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
