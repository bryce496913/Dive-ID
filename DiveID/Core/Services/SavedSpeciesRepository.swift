import Foundation

protocol SavedSpeciesRepository: Sendable {
    func fetchSavedSpecies() async throws -> [Species]
    func save(_ species: Species) async throws
    func remove(_ species: Species) async throws
    func isSaved(_ species: Species) async throws -> Bool
}

actor InMemorySavedSpeciesRepository: SavedSpeciesRepository {
    private var speciesByID: [UUID: Species]

    init(initialSpecies: [Species] = []) {
        speciesByID = Dictionary(uniqueKeysWithValues: initialSpecies.map { ($0.id, $0) })
    }

    func fetchSavedSpecies() -> [Species] { speciesByID.values.sorted { $0.commonName < $1.commonName } }
    func save(_ species: Species) { speciesByID[species.id] = species }
    func remove(_ species: Species) { speciesByID.removeValue(forKey: species.id) }
    func isSaved(_ species: Species) -> Bool { speciesByID[species.id] != nil }
}

struct SavedSpeciesFile: Codable, Sendable {
    let schemaVersion: Int
    var species: [Species]
}

enum SavedSpeciesRepositoryError: Error { case unsupportedSchema, corruptData, storageUnavailable }

actor JSONSavedSpeciesRepository: SavedSpeciesRepository {
    static let schemaVersion = 1
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            guard let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw SavedSpeciesRepositoryError.storageUnavailable
            }
            let appDirectory = directory.appendingPathComponent("DiveID", isDirectory: true)
            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            self.fileURL = appDirectory.appendingPathComponent("saved-species.json")
        }
    }

    func fetchSavedSpecies() throws -> [Species] {
        try read().values.sorted { $0.commonName.localizedCaseInsensitiveCompare($1.commonName) == .orderedAscending }
    }

    func save(_ species: Species) throws {
        var values = try read()
        values[species.id] = species
        try write(values)
    }

    func remove(_ species: Species) throws {
        var values = try read()
        values.removeValue(forKey: species.id)
        try write(values)
    }

    func isSaved(_ species: Species) throws -> Bool { try read()[species.id] != nil }

    private func read() throws -> [UUID: Species] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let envelope = try JSONDecoder().decode(SavedSpeciesFile.self, from: Data(contentsOf: fileURL))
            guard envelope.schemaVersion == Self.schemaVersion else { throw SavedSpeciesRepositoryError.unsupportedSchema }
            return Dictionary(uniqueKeysWithValues: envelope.species.map { ($0.id, $0) })
        } catch let error as SavedSpeciesRepositoryError {
            throw error
        } catch {
            throw SavedSpeciesRepositoryError.corruptData
        }
    }

    private func write(_ values: [UUID: Species]) throws {
        let envelope = SavedSpeciesFile(schemaVersion: Self.schemaVersion, species: values.values.sorted { $0.id.uuidString < $1.id.uuidString })
        let data = try JSONEncoder().encode(envelope)
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: [.atomic])
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }
}
