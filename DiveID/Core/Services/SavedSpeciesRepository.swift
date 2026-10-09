import Foundation

protocol SavedIdentificationRepository: Sendable {
    func fetchAll() async throws -> [SavedIdentification]
    func save(_ identification: SavedIdentification) async throws -> SavedIdentification
    func remove(id: UUID) async throws
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) async throws -> SavedIdentification?
}

actor InMemorySavedIdentificationRepository: SavedIdentificationRepository {
    private var values: [UUID: SavedIdentification] = [:]
    init(initial: [SavedIdentification] = []) { values = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) }) }
    func fetchAll() -> [SavedIdentification] { values.values.sorted { $0.identifiedAt > $1.identifiedAt } }
    func save(_ value: SavedIdentification) -> SavedIdentification { if let session = value.sourceSessionID, let existing = values.values.first(where: { $0.sourceSessionID == session && $0.species.id == value.species.id }) { return existing }; values[value.id] = value; return value }
    func remove(id: UUID) { values.removeValue(forKey: id) }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) -> SavedIdentification? { values.values.first { $0.sourceSessionID == sourceSessionID && $0.species.id == speciesID } }
}

struct SavedIdentificationFile: Codable, Sendable { let schemaVersion: Int; var identifications: [SavedIdentification] }
private struct LegacySavedSpeciesFile: Codable { let schemaVersion: Int; let species: [Species] }
enum SavedIdentificationRepositoryError: Error, LocalizedError {
    case unsupportedSchema, corruptData, storageUnavailable
    case initializationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "Saved storage uses a newer format. Update DiveID and retry."
        case .corruptData: "Saved storage could not be read. Your file has not been reset. Retry, or restore a readable backup."
        case .storageUnavailable, .initializationFailed:
            "Saved storage is unavailable. Check available device storage and retry. Offline search is still available."
        }
    }

    static func message(for error: Error) -> String {
        (error as? Self)?.errorDescription
            ?? "Saved storage could not be accessed. Check available device storage and retry."
    }
}

/// Production storage only. A failed initialization is reported to the caller;
/// the next user operation retries the same persistent factory, never memory storage.
actor PersistentSavedIdentificationRepository: SavedIdentificationRepository {
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
}

actor JSONSavedIdentificationRepository: SavedIdentificationRepository {
    static let schemaVersion = 2
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
    func fetchAll() throws -> [SavedIdentification] { try read().sorted { $0.identifiedAt > $1.identifiedAt } }
    func save(_ value: SavedIdentification) throws -> SavedIdentification { var values = try read(); if let session = value.sourceSessionID, let existing = values.first(where: { $0.sourceSessionID == session && $0.species.id == value.species.id }) { return existing }; values.append(value); try write(values); return value }
    func remove(id: UUID) throws { var values = try read(); values.removeAll { $0.id == id }; try write(values) }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) throws -> SavedIdentification? { try read().first { $0.sourceSessionID == sourceSessionID && $0.species.id == speciesID } }
    private func read() throws -> [SavedIdentification] {
        let sourceURL: URL
        let data: Data
        if let current = try dataIfPresent(at: fileURL) {
            sourceURL = fileURL
            data = current
        } else if let legacyFileURL, let legacy = try dataIfPresent(at: legacyFileURL) {
            sourceURL = legacyFileURL
            data = legacy
        } else { return [] }
        if let envelope = try? JSONDecoder().decode(SavedIdentificationFile.self, from: data) { guard envelope.schemaVersion == Self.schemaVersion else { throw SavedIdentificationRepositoryError.unsupportedSchema }; if sourceURL != fileURL { try write(envelope.identifications) }; return envelope.identifications }
        if let legacy = try? JSONDecoder().decode(LegacySavedSpeciesFile.self, from: data), legacy.schemaVersion == 1 {
            let migrated = legacy.species.map { species in SavedIdentification(match: .init(id: species.id, species: species, score: 0, scoreKind: .relativeMatch, strength: .weak, explanation: "Saved before identification details were available.", distinguishingFeatures: [], cautions: [], taxonomicResolution: .species)) }
            try write(migrated); return migrated
        }
        throw SavedIdentificationRepositoryError.corruptData
    }
    private func dataIfPresent(at url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch CocoaError.fileReadNoSuchFile { return nil }
    }
    private func write(_ values: [SavedIdentification]) throws {
        let data = try JSONEncoder().encode(SavedIdentificationFile(schemaVersion: Self.schemaVersion, identifications: values)); let directory = fileURL.deletingLastPathComponent(); try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Atomic replacement preserves the previous file if writing fails. Avoid
        // a separate remove/rename sequence that could lose confirmed records.
        try writeData(data, fileURL)
    }
}
