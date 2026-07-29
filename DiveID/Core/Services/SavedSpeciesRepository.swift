import Foundation

protocol SavedSpeciesRepository: Sendable {
    func fetchSavedSpecies() async throws -> [Species]
    func save(_ species: Species) async throws
    func remove(_ species: Species) async throws
    func isSaved(_ species: Species) async -> Bool
}

actor InMemorySavedSpeciesRepository: SavedSpeciesRepository {
    private var speciesByID: [UUID: Species]
    init(initialSpecies: [Species] = []) { speciesByID = Dictionary(uniqueKeysWithValues: initialSpecies.map { ($0.id, $0) }) }
    func fetchSavedSpecies() -> [Species] { speciesByID.values.sorted { $0.commonName < $1.commonName } }
    func save(_ species: Species) { speciesByID[species.id] = species }
    func remove(_ species: Species) { speciesByID.removeValue(forKey: species.id) }
    func isSaved(_ species: Species) -> Bool { speciesByID[species.id] != nil }
}
