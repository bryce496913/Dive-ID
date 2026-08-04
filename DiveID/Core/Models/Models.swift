import Foundation

struct Species: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let commonName: String
    let scientificName: String
    let summary: String
    let visualCharacteristics: [String]
    let habitat: String
    let geographicRange: String
    let imageAssetName: String?
}

enum MatchScoreKind: String, Codable, Sendable {
    case relativeMatch
    case calibratedProbability
}

enum MatchStrength: String, CaseIterable, Sendable {
    case strong = "Strong match"
    case good = "Good match"
    case possible = "Possible match"
    case weak = "Weak match"

    static func band(for score: Double) -> Self {
        switch score {
        case 0.85...: .strong
        case 0.65..<0.85: .good
        case 0.40..<0.65: .possible
        default: .weak
        }
    }
}

struct IdentificationMatch: Identifiable, Hashable, Sendable {
    let id: UUID
    let species: Species
    let score: Double
    let scoreKind: MatchScoreKind

    var matchStrength: MatchStrength { .band(for: score) }
}

enum WaterType: String, Codable, CaseIterable, Sendable {
    case saltwater, freshwater, brackish, unknown
}

struct IdentificationContext: Hashable, Codable, Sendable {
    var region: String?
    var waterType: WaterType?
    var approximateDepthMeters: Double?
    var habitat: String?
    var approximateSize: String?
    var behavior: String?
    var observedAt: Date?

    static let empty = IdentificationContext()
}

struct ProcessedPhotoReference: Hashable, Codable, Sendable {
    let id: UUID
}

enum ProcessedPhotoFormat: String, Codable, Sendable { case jpeg }

struct ProcessedPhoto: Hashable, Sendable {
    let id: UUID
    let previewData: Data
    let uploadData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let format: ProcessedPhotoFormat

    var reference: ProcessedPhotoReference { .init(id: id) }
}

enum IdentificationSource: Hashable, Sendable {
    case description(String)
    case processedPhoto(ProcessedPhotoReference)
}

struct IdentificationRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let source: IdentificationSource
    let context: IdentificationContext
    let createdAt: Date

    init(id: UUID = UUID(), source: IdentificationSource, context: IdentificationContext = .empty, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.context = context
        self.createdAt = createdAt
    }
}

struct IdentificationSessionResult: Sendable {
    let matches: [IdentificationMatch]
    let completedAt: Date
}

enum LoadState<Value> {
    case idle, loading, loaded(Value), empty, failed(String)
}
