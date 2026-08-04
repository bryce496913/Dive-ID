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
enum SavedIdentificationRepositoryError: Error { case unsupportedSchema, corruptData, storageUnavailable }

actor JSONSavedIdentificationRepository: SavedIdentificationRepository {
    static let schemaVersion = 2
    private let fileURL: URL; private let legacyFileURL: URL?; private let fileManager: FileManager
    init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let fileURL { self.fileURL = fileURL; self.legacyFileURL = nil; return }
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
        if fileManager.fileExists(atPath: fileURL.path) { sourceURL = fileURL }
        else if let legacyFileURL, fileManager.fileExists(atPath: legacyFileURL.path) { sourceURL = legacyFileURL }
        else { return [] }
        let data = try Data(contentsOf: sourceURL)
        if let envelope = try? JSONDecoder().decode(SavedIdentificationFile.self, from: data) { guard envelope.schemaVersion == Self.schemaVersion else { throw SavedIdentificationRepositoryError.unsupportedSchema }; if sourceURL != fileURL { try write(envelope.identifications) }; return envelope.identifications }
        if let legacy = try? JSONDecoder().decode(LegacySavedSpeciesFile.self, from: data), legacy.schemaVersion == 1 {
            let migrated = legacy.species.map { species in SavedIdentification(match: .init(id: species.id, species: species, score: 0, scoreKind: .relativeMatch, strength: .weak, explanation: "Saved before identification details were available.", distinguishingFeatures: [], cautions: [], taxonomicResolution: .species)) }
            try write(migrated); return migrated
        }
        throw SavedIdentificationRepositoryError.corruptData
    }
    private func write(_ values: [SavedIdentification]) throws {
        let data = try JSONEncoder().encode(SavedIdentificationFile(schemaVersion: Self.schemaVersion, identifications: values)); let directory = fileURL.deletingLastPathComponent(); try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do { try data.write(to: temporary, options: .atomic); if fileManager.fileExists(atPath: fileURL.path) { _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary) } else { try fileManager.moveItem(at: temporary, to: fileURL) } }
        catch { try? fileManager.removeItem(at: temporary); throw error }
    }
}
