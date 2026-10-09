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

    init(species: Species, match: IdentificationMatch?, repository: any SavedIdentificationRepository) {
        self.species = species
        self.match = match
        self.repository = repository
        savedIdentificationID = nil
    }

    init(saved: SavedIdentification, repository: any SavedIdentificationRepository) { species = saved.species; match = saved.match; self.repository = repository; savedIdentificationID = saved.id; isSaved = true }

    func load() async {
        guard !isUpdatingSavedState else { return }
        isUpdatingSavedState = true
        defer { isUpdatingSavedState = false }
        do {
            let values = try await repository.fetchAll()
            let saved = values.first { value in
                if let savedIdentificationID { return value.id == savedIdentificationID }
                guard let session = match?.sourceSessionID else { return false }
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
            } else if let match {
                let persisted = try await repository.save(SavedIdentification(match: match))
                savedIdentificationID = persisted.id
                isSaved = true
            }
            errorMessage = nil
        } catch {
            retrySaveChange = true
            errorMessage = "The identification could not be " + (isSaved ? "removed. " : "saved. ")
                + SavedIdentificationRepositoryError.message(for: error)
        }
    }
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
