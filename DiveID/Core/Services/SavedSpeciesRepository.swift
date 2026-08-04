import Foundation

protocol SavedIdentificationRepository: Sendable {
    func fetchAll() async throws -> [SavedIdentification]
    func save(_ identification: SavedIdentification) async throws
    func remove(id: UUID) async throws
    func contains(sourceSessionID: UUID) async throws -> Bool
}

actor InMemorySavedIdentificationRepository: SavedIdentificationRepository {
    private var values: [UUID: SavedIdentification] = [:]
    init(initial: [SavedIdentification] = []) { values = Dictionary(uniqueKeysWithValues: initial.map { ($0.id, $0) }) }
    func fetchAll() -> [SavedIdentification] { values.values.sorted { $0.identifiedAt > $1.identifiedAt } }
    func save(_ value: SavedIdentification) { if let session = value.sourceSessionID, values.values.contains(where: { $0.sourceSessionID == session && $0.species.id == value.species.id }) { return }; values[value.id] = value }
    func remove(id: UUID) { values.removeValue(forKey: id) }
    func contains(sourceSessionID: UUID) -> Bool { values.values.contains { $0.sourceSessionID == sourceSessionID } }
}

struct SavedIdentificationFile: Codable, Sendable { let schemaVersion: Int; var identifications: [SavedIdentification] }
private struct LegacySavedSpeciesFile: Codable { let schemaVersion: Int; let species: [Species] }
enum SavedIdentificationRepositoryError: Error { case unsupportedSchema, corruptData, storageUnavailable }

actor JSONSavedIdentificationRepository: SavedIdentificationRepository {
    static let schemaVersion = 2
    private let fileURL: URL; private let fileManager: FileManager
    init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let fileURL { self.fileURL = fileURL; return }
        guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { throw SavedIdentificationRepositoryError.storageUnavailable }
        let appDirectory = directory.appendingPathComponent("DiveID", isDirectory: true); try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        self.fileURL = appDirectory.appendingPathComponent("saved-species.json")
    }
    func fetchAll() throws -> [SavedIdentification] { try read().sorted { $0.identifiedAt > $1.identifiedAt } }
    func save(_ value: SavedIdentification) throws { var values = try read(); if let session = value.sourceSessionID, values.contains(where: { $0.sourceSessionID == session && $0.species.id == value.species.id }) { return }; values.append(value); try write(values) }
    func remove(id: UUID) throws { var values = try read(); values.removeAll { $0.id == id }; try write(values) }
    func contains(sourceSessionID: UUID) throws -> Bool { try read().contains { $0.sourceSessionID == sourceSessionID } }
    private func read() throws -> [SavedIdentification] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }; let data = try Data(contentsOf: fileURL)
        if let envelope = try? JSONDecoder().decode(SavedIdentificationFile.self, from: data) { guard envelope.schemaVersion == Self.schemaVersion else { throw SavedIdentificationRepositoryError.unsupportedSchema }; return envelope.identifications }
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
