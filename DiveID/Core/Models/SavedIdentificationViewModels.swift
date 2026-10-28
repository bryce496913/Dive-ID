import Foundation
import Observation

@MainActor @Observable
final class SpeciesDetailViewModel {
    let species: Species
    let match: IdentificationMatch?
    var isSaved = false
    var errorMessage: String?
    private var retrySaveChange = false
    private(set) var savedIdentificationID: UUID?
    private(set) var isUpdatingSavedState = false
    private let repository: any SavedIdentificationRepository
    /// Shown after a new save: today's dive (if any), another dive, a new dive, or skip.
    var addToDiveOffer: AddToDiveOffer?
    private var diveLog: (any DiveLogRepository)? { repository as? any DiveLogRepository }

    init(species: Species, match: IdentificationMatch?, repository: any SavedIdentificationRepository) {
        self.species = species
        self.match = match
        self.repository = repository
        savedIdentificationID = nil
    }

    init(saved: SavedIdentification, repository: any SavedIdentificationRepository) {
        species = saved.species; match = saved.isFromFieldGuide ? nil : saved.match  // no strength or evidence was ever shown
        self.repository = repository; savedIdentificationID = saved.id; isSaved = true
    }

    func load() async {
        guard !isUpdatingSavedState else { return }
        isUpdatingSavedState = true
        defer { isUpdatingSavedState = false }
        do {
            let values = try await repository.fetchAll()
            let saved = values.first { value in
                if let savedIdentificationID { return value.id == savedIdentificationID }
                guard let match else { return value.isFromFieldGuide && value.species.id == species.id }
                guard let session = match.sourceSessionID else { return false }
                return value.sourceSessionID == session && value.species.id == species.id
            }
            savedIdentificationID = saved?.id
            isSaved = saved != nil
            errorMessage = nil
        } catch {
            retrySaveChange = false
            errorMessage = SavedIdentificationRepositoryError.message(for: error)
        }
    }

    func retry() async {
        if retrySaveChange { await toggleSaved() } else { await load() }
    }

    func toggleSaved() async {
        guard !isUpdatingSavedState else { return }
        isUpdatingSavedState = true
        defer { isUpdatingSavedState = false }
        do {
            if isSaved {
                guard let id = savedIdentificationID else { errorMessage = "The saved identification could not be found."; return }
                try await repository.remove(id: id)
                savedIdentificationID = nil
                isSaved = false
            } else {
                // From a search, the match; from the field guide, the species alone.
                let value = match.map { SavedIdentification(match: $0) } ?? SavedIdentification(fieldGuideSpecies: species)
                let persisted = try await repository.save(value)
                savedIdentificationID = persisted.id
                isSaved = true
                await offerAddToDive(sightingID: persisted.id)
            }
            errorMessage = nil
        } catch {
            retrySaveChange = true
            errorMessage = "The identification could not be " + (isSaved ? "removed. " : "saved. ")
                + SavedIdentificationRepositoryError.message(for: error)
        }
    }
}

extension SpeciesDetailViewModel {
    /// Offers "Add to dive" once the save is confirmed. A store without dives offers nothing,
    /// and a dive list that can't be read still offers a new dive or skip.
    func offerAddToDive(sightingID: UUID, today: Date = Date(), calendar: Calendar = .current) async {
        guard let diveLog else { return }
        let dives = ((try? await diveLog.dives()) ?? []).map(\.dive)
        let day = calendar.dateComponents([.year, .month, .day], from: today)
        let todayDate = LocalDate(year: day.year ?? 0, month: day.month ?? 0, day: day.day ?? 0)
        addToDiveOffer = AddToDiveOffer(sightingID: sightingID, todaysDive: dives.first { $0.date == todayDate }, dives: dives)
    }

    /// Skip: one tap, nothing changes.
    func skipAddToDive() { addToDiveOffer = nil }

    func addToDive(_ dive: Dive) async {
        guard let offer = addToDiveOffer, let diveLog else { return }
        do {
            try await diveLog.assign(sightingIDs: [offer.sightingID], toDive: dive.id)
            addToDiveOffer = nil
            errorMessage = nil
        } catch {
            errorMessage = "The identification is saved, but couldn't be added to the dive. " + SavedIdentificationRepositoryError.message(for: error)
        }
    }

    /// Creates the dive from the form, then adds this sighting to it.
    @discardableResult
    func createDiveAndAdd(_ form: DiveForm) async -> Bool {
        guard let diveLog, let dive = form.makeDive() else { return false }
        do {
            let created = try await diveLog.createDive(dive)
            await addToDive(created)
            return addToDiveOffer == nil
        } catch {
            errorMessage = "The identification is saved, but the dive couldn't be created. " + SavedIdentificationRepositoryError.message(for: error)
            return false
        }
    }
}

/// What "Add to dive" can offer for one saved sighting.
struct AddToDiveOffer: Identifiable, Hashable, Sendable {
    var id: UUID { sightingID }
    let sightingID: UUID
    let todaysDive: Dive?
    /// Every dive, newest first, to pick another.
    let dives: [Dive]
}

@MainActor @Observable
final class SavedSpeciesViewModel {
    var identifications: [SavedIdentification] = []
    var isLoading = true
    var errorMessage: String?
    private(set) var isUpdating = false
    private var pendingRemoval: SavedIdentification?
    private let repository: any SavedIdentificationRepository

    init(repository: any SavedIdentificationRepository) { self.repository = repository }

    func load() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isLoading = false; isUpdating = false }
        do {
            identifications = try await repository.fetchAll()
            errorMessage = nil
            pendingRemoval = nil
        } catch {
            pendingRemoval = nil
            errorMessage = SavedIdentificationRepositoryError.message(for: error)
        }
    }

    func remove(_ item: SavedIdentification) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await repository.remove(id: item.id)
            // Removal has committed. Do not make UI success depend on another read.
            identifications.removeAll { $0.id == item.id }
            errorMessage = nil
            pendingRemoval = nil
        } catch {
            pendingRemoval = item
            errorMessage = "The identification could not be removed. "
                + SavedIdentificationRepositoryError.message(for: error)
        }
    }

    func retry() async {
        if let pendingRemoval { await remove(pendingRemoval) } else { await load() }
    }
}
