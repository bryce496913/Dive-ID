import Foundation

protocol SavedIdentificationRepository: Sendable {
    func fetchAll() async throws -> [SavedIdentification]
    func save(_ identification: SavedIdentification) async throws -> SavedIdentification
    func remove(id: UUID) async throws
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) async throws -> SavedIdentification?
}

actor InMemorySavedIdentificationRepository: SavedIdentificationRepository, DiveLogRepository {
    private var store: SavedStore
    init(initial: [SavedIdentification] = [], dives: [Dive] = []) { store = SavedStore(identifications: initial, dives: dives) }
    func fetchAll() -> [SavedIdentification] { store.sortedIdentifications }
    func save(_ value: SavedIdentification) -> SavedIdentification {
        if let existing = store.identifications.first(where: { SavedIdentificationFile.isSame($0, value) }) { return existing }
        store.identifications.removeAll { $0.id == value.id }  // same ID replaces, as before
        store.identifications.append(value); return value
    }
    func remove(id: UUID) { store.identifications.removeAll { $0.id == id } }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) -> SavedIdentification? { store.identifications.first { $0.sourceSessionID == sourceSessionID && $0.species.id == speciesID } }
    func dives() -> [DiveWithSightings] { store.divesWithSightings() }
    func createDive(_ dive: Dive) throws -> Dive { try store.createDive(dive) }
    func updateDive(_ dive: Dive) throws -> Dive { try store.updateDive(dive) }
    func deleteDive(id: UUID, sightings: DiveDeletion) throws { try store.deleteDive(id: id, sightings: sightings) }
    func assign(sightingIDs: [UUID], toDive diveID: UUID) throws { try store.assign(sightingIDs: sightingIDs, toDive: diveID) }
    func unassign(sightingIDs: [UUID]) throws { try store.assign(sightingIDs: sightingIDs, toDive: nil) }
    func updateSighting(id: UUID, depth: Depth?, notes: String?) throws { try store.updateSighting(id: id, depth: depth, notes: notes) }
}

/// The saved file. Schema 3 adds `dives`; a schema 2 file has none and decodes with an
/// empty list.
struct SavedIdentificationFile: Codable, Sendable {
    let schemaVersion: Int
    var identifications: [SavedIdentification]
    var dives: [Dive]

    init(schemaVersion: Int, identifications: [SavedIdentification], dives: [Dive] = []) {
        self.schemaVersion = schemaVersion; self.identifications = identifications; self.dives = dives
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, identifications, dives }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        identifications = try c.decode([SavedIdentification].self, forKey: .identifications)
        dives = try c.decodeIfPresent([Dive].self, forKey: .dives) ?? []
    }

    /// A save that already exists: the same search's species, or the same species saved from the field guide.
    static func isSame(_ existing: SavedIdentification, _ new: SavedIdentification) -> Bool {
        if let session = new.sourceSessionID { return existing.sourceSessionID == session && existing.species.id == new.species.id }
        return new.isFromFieldGuide && existing.isFromFieldGuide && existing.species.id == new.species.id
    }
}
private struct LegacySavedSpeciesFile: Codable { let schemaVersion: Int; let species: [Species] }
enum SavedIdentificationRepositoryError: Error, LocalizedError, Equatable {
    case unsupportedSchema, corruptData, storageUnavailable
    case initializationFailed
    case diveNotFound, sightingNotFound
    case invalidDive(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Saved storage uses a newer format. Update DiveID and retry."
        case .corruptData: "Saved storage could not be read. Your file has not been reset. Retry, or restore a readable backup."
        case .storageUnavailable, .initializationFailed:
            "Saved storage is unavailable. Check available device storage and retry. Offline search is still available."
        case .diveNotFound: "That dive could not be found. It may have been deleted."
        case .sightingNotFound: "That saved identification could not be found. It may have been removed."
        case .invalidDive(let reason): reason
        }
    }

    static func message(for error: Error) -> String {
        (error as? Self)?.errorDescription
            ?? "Saved storage could not be accessed. Check available device storage and retry."
    }
}

/// Production storage only. A failed initialization is reported to the caller;
/// the next user operation retries the same persistent factory, never memory storage.
actor PersistentSavedIdentificationRepository: SavedIdentificationRepository, DiveLogRepository {
    private let makeRepository: @Sendable () throws -> JSONSavedIdentificationRepository
    private var repository: JSONSavedIdentificationRepository?

    init(makeRepository: @escaping @Sendable () throws -> JSONSavedIdentificationRepository = {
        try JSONSavedIdentificationRepository()
    }) {
        self.makeRepository = makeRepository
    }

    private func persistentRepository() throws -> JSONSavedIdentificationRepository {
        if let repository { return repository }
        do {
            let repository = try makeRepository()
            self.repository = repository
            return repository
        } catch {
            throw SavedIdentificationRepositoryError.initializationFailed
        }
    }

    func fetchAll() async throws -> [SavedIdentification] {
        try await persistentRepository().fetchAll()
    }
    func save(_ value: SavedIdentification) async throws -> SavedIdentification {
        try await persistentRepository().save(value)
    }
    func remove(id: UUID) async throws {
        try await persistentRepository().remove(id: id)
    }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) async throws -> SavedIdentification? {
        try await persistentRepository().savedIdentification(sourceSessionID: sourceSessionID, speciesID: speciesID)
    }
    func dives() async throws -> [DiveWithSightings] { try await persistentRepository().dives() }
    func createDive(_ dive: Dive) async throws -> Dive { try await persistentRepository().createDive(dive) }
    func updateDive(_ dive: Dive) async throws -> Dive { try await persistentRepository().updateDive(dive) }
    func deleteDive(id: UUID, sightings: DiveDeletion) async throws { try await persistentRepository().deleteDive(id: id, sightings: sightings) }
    func assign(sightingIDs: [UUID], toDive diveID: UUID) async throws { try await persistentRepository().assign(sightingIDs: sightingIDs, toDive: diveID) }
    func unassign(sightingIDs: [UUID]) async throws { try await persistentRepository().unassign(sightingIDs: sightingIDs) }
    func updateSighting(id: UUID, depth: Depth?, notes: String?) async throws {
        try await persistentRepository().updateSighting(id: id, depth: depth, notes: notes)
    }
}

actor JSONSavedIdentificationRepository: SavedIdentificationRepository, DiveLogRepository {
    static let schemaVersion = 3
    /// Read as the current schema with no dives; written as schema 3 only on the next change,
    /// so opening the app never rewrites it.
    static let previousSchemaVersion = 2
    private let fileURL: URL; private let legacyFileURL: URL?; private let fileManager: FileManager
    private let writeData: @Sendable (Data, URL) throws -> Void
    init(fileURL: URL? = nil, fileManager: FileManager = .default,
         writeData: @escaping @Sendable (Data, URL) throws -> Void = { data, url in
             try data.write(to: url, options: .atomic)
         }) throws {
        self.writeData = writeData
        self.fileManager = fileManager
        if let fileURL {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            self.fileURL = fileURL
            self.legacyFileURL = nil
            return
        }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw SavedIdentificationRepositoryError.storageUnavailable }
        let appDirectory = directory.appendingPathComponent("DiveID", isDirectory: true); try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        self.fileURL = appDirectory.appendingPathComponent("saved-identifications.json")
        self.legacyFileURL = appDirectory.appendingPathComponent("saved-species.json")
    }
    func fetchAll() throws -> [SavedIdentification] { try read().sortedIdentifications }
    func save(_ value: SavedIdentification) throws -> SavedIdentification { var store = try read(); if let existing = store.identifications.first(where: { SavedIdentificationFile.isSame($0, value) }) { return existing }; store.identifications.append(value); try write(store); return value }
    func remove(id: UUID) throws { var store = try read(); store.identifications.removeAll { $0.id == id }; try write(store) }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) throws -> SavedIdentification? { try read().identifications.first { $0.sourceSessionID == sourceSessionID && $0.species.id == speciesID } }

    // MARK: Dives. Each change is checked in full before the single atomic write.
    func dives() throws -> [DiveWithSightings] { try read().divesWithSightings() }
    func createDive(_ dive: Dive) throws -> Dive { try change { try $0.createDive(dive) } }
    func updateDive(_ dive: Dive) throws -> Dive { try change { try $0.updateDive(dive) } }
    func deleteDive(id: UUID, sightings: DiveDeletion) throws { try change { try $0.deleteDive(id: id, sightings: sightings) } }
    func assign(sightingIDs: [UUID], toDive diveID: UUID) throws { try change { try $0.assign(sightingIDs: sightingIDs, toDive: diveID) } }
    func unassign(sightingIDs: [UUID]) throws { try change { try $0.assign(sightingIDs: sightingIDs, toDive: nil) } }
    func updateSighting(id: UUID, depth: Depth?, notes: String?) throws { try change { try $0.updateSighting(id: id, depth: depth, notes: notes) } }

    private func change<T>(_ body: (inout SavedStore) throws -> T) throws -> T {
        var store = try read()
        let result = try body(&store)  // a rejected change throws here, before anything is written
        try write(store)
        return result
    }

    private func read() throws -> SavedStore {
        let sourceURL: URL
        let data: Data
        if let current = try dataIfPresent(at: fileURL) {
            sourceURL = fileURL
            data = current
        } else if let legacyFileURL, let legacy = try dataIfPresent(at: legacyFileURL) {
            sourceURL = legacyFileURL
            data = legacy
        } else { return SavedStore() }
        if let envelope = try? JSONDecoder().decode(SavedIdentificationFile.self, from: data) {
            switch envelope.schemaVersion {
            case Self.schemaVersion:
                break
            case Self.previousSchemaVersion:
                // Schema 2 had no dives. Its records load with diveID nil (decoded as absent).
                guard envelope.dives.isEmpty else { throw SavedIdentificationRepositoryError.corruptData }
            default:
                throw SavedIdentificationRepositoryError.unsupportedSchema
            }
            let store = SavedStore(identifications: envelope.identifications, dives: envelope.dives)
            if sourceURL != fileURL { try write(store) }
            return store
        }
        if let legacy = try? JSONDecoder().decode(LegacySavedSpeciesFile.self, from: data), legacy.schemaVersion == 1 {
            let migrated = legacy.species.map { species in SavedIdentification(match: .init(id: species.id, species: species, score: 0, scoreKind: .relativeMatch, strength: .weak, explanation: "Saved before identification details were available.", distinguishingFeatures: [], cautions: [], taxonomicResolution: .species)) }
            let store = SavedStore(identifications: migrated)
            try write(store); return store
        }
        throw SavedIdentificationRepositoryError.corruptData
    }
    private func dataIfPresent(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
    private func write(_ store: SavedStore) throws {
        let data = try JSONEncoder().encode(SavedIdentificationFile(schemaVersion: Self.schemaVersion, identifications: store.identifications, dives: store.dives)); let directory = fileURL.deletingLastPathComponent(); try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic replacement preserves the previous file if writing fails. Avoid
        // a separate remove/rename sequence that could lose confirmed records.
        try writeData(data, fileURL)
    }
}
