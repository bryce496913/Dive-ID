import Foundation

/// A calendar day where the dive happened, stored as "2026-03-14". Deliberately not a
/// timestamp: a dive on 14 March in Bonaire stays 14 March when viewed at home.
struct LocalDate: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int, month: Int, day: Int

    init?(year: Int, month: Int, day: Int) {
        var components = DateComponents(); components.year = year; components.month = month; components.day = day
        let calendar = Calendar(identifier: .gregorian)
        guard (1...9999).contains(year), components.isValidDate(in: calendar) else { return nil }
        self.year = year; self.month = month; self.day = day
    }

    init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalDate(text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a YYYY-MM-DD date: \(text)")) }
        self = value
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

/// A local clock time, "09:30", in the dive's own time zone.
struct LocalTime: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let hour: Int, minute: Int

    init?(hour: Int, minute: Int) {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        self.hour = hour; self.minute = minute
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        self.init(hour: h, minute: m)
    }

    var description: String { String(format: "%02d:%02d", hour, minute) }
    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute) }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalTime(text) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an HH:mm time: \(text)")) }
        self = value
    }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
}

/// A depth with its units (metres or feet, as the diver logged it).
struct Depth: Codable, Hashable, Sendable {
    let value: Double
    let unit: DepthUnit
    var isValid: Bool { value.isFinite && value >= 0 }
}

/// A horizontal distance, used for visibility (metres or feet).
struct Distance: Codable, Hashable, Sendable {
    let value: Double
    let unit: DepthUnit
    var isValid: Bool { value.isFinite && value >= 0 }
}

enum TemperatureUnit: String, Codable, CaseIterable, Sendable { case celsius, fahrenheit }

struct Temperature: Codable, Hashable, Sendable {
    let value: Double
    let unit: TemperatureUnit
    var isValid: Bool { value.isFinite }
}

/// A dive. Only the ID and date are required; everything else is optional because divers
/// often don't know or log it.
struct Dive: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var date: LocalDate
    var startTime: LocalTime?
    var siteName: String?
    /// The broad region (a pack or region ID), if the diver chose one.
    var regionID: OfflineIdentificationPackID?
    var maximumDepth: Depth?
    var durationMinutes: Int?
    var waterTemperature: Temperature?
    var visibility: Distance?
    var notes: String?
    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), date: LocalDate, startTime: LocalTime? = nil, siteName: String? = nil,
         regionID: OfflineIdentificationPackID? = nil, maximumDepth: Depth? = nil, durationMinutes: Int? = nil,
         waterTemperature: Temperature? = nil, visibility: Distance? = nil, notes: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.date = date; self.startTime = startTime; self.siteName = siteName; self.regionID = regionID
        self.maximumDepth = maximumDepth; self.durationMinutes = durationMinutes; self.waterTemperature = waterTemperature
        self.visibility = visibility; self.notes = notes; self.createdAt = createdAt; updatedAt = createdAt
    }

    /// Why the dive can't be stored, or nil when it can.
    var invalidReason: String? {
        if let maximumDepth, !maximumDepth.isValid { return "Maximum depth must be zero or more." }
        if let visibility, !visibility.isValid { return "Visibility must be zero or more." }
        if let waterTemperature, !waterTemperature.isValid { return "Water temperature must be a number." }
        if let durationMinutes, durationMinutes <= 0 { return "Duration must be more than zero minutes." }
        return nil
    }

    /// Newest first: by date, then start time (a dive without one comes last within its
    /// day), then when it was created.
    static func newestFirst(_ lhs: Dive, _ rhs: Dive) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        switch (lhs.startTime, rhs.startTime) {
        case let (l?, r?) where l != r: return l > r
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.createdAt > rhs.createdAt
        }
    }
}

/// A dive and the saved identifications ("sightings") assigned to it, newest first.
struct DiveWithSightings: Hashable, Sendable {
    let dive: Dive
    let sightings: [SavedIdentification]
}

/// What happens to a dive's sightings when the dive is deleted. Keeping them is the default.
enum DiveDeletion: Sendable { case keepUnassigned, deleteSightings }

/// Dives and the sightings that belong to them.
protocol DiveLogRepository: Sendable {
    func dives() async throws -> [DiveWithSightings]
    func createDive(_ dive: Dive) async throws -> Dive
    func updateDive(_ dive: Dive) async throws -> Dive
    func deleteDive(id: UUID, sightings: DiveDeletion) async throws
    func assign(sightingIDs: [UUID], toDive diveID: UUID) async throws
    func unassign(sightingIDs: [UUID]) async throws
    func updateSighting(id: UUID, depth: Depth?, notes: String?) async throws
}

extension DiveLogRepository {
    func deleteDive(id: UUID) async throws { try await deleteDive(id: id, sightings: .keepUnassigned) }
}

/// Saved identifications and dives together: the rules every store applies, so the file and
/// in-memory stores behave alike. Each mutation checks everything before changing anything.
struct SavedStore: Hashable, Sendable {
    var identifications: [SavedIdentification] = []
    var dives: [Dive] = []

    var sortedIdentifications: [SavedIdentification] { identifications.sorted { $0.identifiedAt > $1.identifiedAt } }

    func divesWithSightings() -> [DiveWithSightings] {
        let byDive = Dictionary(grouping: identifications.filter { $0.diveID != nil }, by: { $0.diveID! })
        return dives.sorted(by: Dive.newestFirst).map { dive in
            DiveWithSightings(dive: dive, sightings: (byDive[dive.id] ?? []).sorted { $0.identifiedAt > $1.identifiedAt })
        }
    }

    mutating func createDive(_ dive: Dive) throws -> Dive {
        if let reason = dive.invalidReason { throw SavedIdentificationRepositoryError.invalidDive(reason) }
        guard !dives.contains(where: { $0.id == dive.id }) else { throw SavedIdentificationRepositoryError.invalidDive("This dive already exists.") }
        dives.append(dive)
        return dive
    }

    mutating func updateDive(_ dive: Dive, now: Date = Date()) throws -> Dive {
        if let reason = dive.invalidReason { throw SavedIdentificationRepositoryError.invalidDive(reason) }
        guard let index = dives.firstIndex(where: { $0.id == dive.id }) else { throw SavedIdentificationRepositoryError.diveNotFound }
        var updated = Dive(id: dive.id, date: dive.date, startTime: dive.startTime, siteName: dive.siteName, regionID: dive.regionID,
                       maximumDepth: dive.maximumDepth, durationMinutes: dive.durationMinutes, waterTemperature: dive.waterTemperature,
                       visibility: dive.visibility, notes: dive.notes, createdAt: dives[index].createdAt)  // creation time never changes
        updated.updatedAt = now
        dives[index] = updated
        return updated
    }

    mutating func deleteDive(id: UUID, sightings: DiveDeletion) throws {
        guard dives.contains(where: { $0.id == id }) else { throw SavedIdentificationRepositoryError.diveNotFound }
        dives.removeAll { $0.id == id }
        switch sightings {
        case .keepUnassigned:
            for index in identifications.indices where identifications[index].diveID == id { identifications[index].diveID = nil }
        case .deleteSightings:
            identifications.removeAll { $0.diveID == id }
        }
    }

    mutating func assign(sightingIDs: [UUID], toDive diveID: UUID?) throws {
        if let diveID, !dives.contains(where: { $0.id == diveID }) { throw SavedIdentificationRepositoryError.diveNotFound }
        let known = Set(identifications.map(\.id))
        guard Set(sightingIDs).isSubset(of: known) else { throw SavedIdentificationRepositoryError.sightingNotFound }
        let wanted = Set(sightingIDs)
        for index in identifications.indices where wanted.contains(identifications[index].id) { identifications[index].diveID = diveID }
    }

    mutating func updateSighting(id: UUID, depth: Depth?, notes: String?) throws {
        if let depth, !depth.isValid { throw SavedIdentificationRepositoryError.invalidDive("Depth must be zero or more.") }
        guard let index = identifications.firstIndex(where: { $0.id == id }) else { throw SavedIdentificationRepositoryError.sightingNotFound }
        identifications[index].depth = depth
        identifications[index].notes = notes
    }
}
