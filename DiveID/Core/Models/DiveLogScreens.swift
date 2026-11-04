import Foundation
import Observation

/// Saved identifications plus dives: the store behind the Dive Log.
typealias SavedLogRepository = SavedIdentificationRepository & DiveLogRepository

// MARK: Units

/// The diver's units for depth and visibility (and temperature to match), a user setting.
/// The default follows the locale: feet and °F in the US, metres and °C elsewhere.
struct MeasurementPreference: @unchecked Sendable {  // UserDefaults is thread-safe
    let defaults: UserDefaults
    let locale: Locale
    static let key = "diveLogDepthUnit"

    init(defaults: UserDefaults = .standard, locale: Locale = .current) { self.defaults = defaults; self.locale = locale }

    var depthUnit: DepthUnit {
        get { defaults.string(forKey: Self.key).flatMap(DepthUnit.init(rawValue:)) ?? Self.localeDefault(locale) }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.key) }
    }
    var temperatureUnit: TemperatureUnit { depthUnit == .feet ? .fahrenheit : .celsius }

    static func localeDefault(_ locale: Locale) -> DepthUnit { locale.measurementSystem == .us ? .feet : .metres }
}

extension DepthUnit {
    var symbol: String { self == .metres ? "m" : "ft" }
}

extension TemperatureUnit {
    var symbol: String { self == .celsius ? "°C" : "°F" }
}

// MARK: The dive form

/// The add/edit dive form. Every field except the date is optional; numbers are checked
/// for range in the units they were entered in, and stored with those units.
struct DiveForm: Equatable, Sendable {
    enum Field: Hashable, Sendable { case maximumDepth, duration, waterTemperature, visibility }

    var date: Date
    var hasStartTime = false
    var startTime: Date
    var siteName = ""
    var regionID: OfflineIdentificationPackID?
    var depthText = ""
    var durationText = ""
    var temperatureText = ""
    var visibilityText = ""
    var notes = ""
    var depthUnit: DepthUnit
    var temperatureUnit: TemperatureUnit

    /// A new dive: today, units from the setting.
    init(now: Date = Date(), depthUnit: DepthUnit, temperatureUnit: TemperatureUnit) {
        date = now; startTime = now; self.depthUnit = depthUnit; self.temperatureUnit = temperatureUnit
    }

    /// Editing: the stored values in the units they were stored in, so nothing is converted.
    init(editing dive: Dive, depthUnit preferred: DepthUnit, temperatureUnit preferredTemperature: TemperatureUnit, calendar: Calendar = .current) {
        date = calendar.date(from: DateComponents(year: dive.date.year, month: dive.date.month, day: dive.date.day, hour: 12)) ?? Date()
        hasStartTime = dive.startTime != nil
        startTime = calendar.date(from: DateComponents(year: dive.date.year, month: dive.date.month, day: dive.date.day,
                                                       hour: dive.startTime?.hour ?? 9, minute: dive.startTime?.minute ?? 0)) ?? date
        siteName = dive.siteName ?? ""
        regionID = dive.regionID
        depthUnit = dive.maximumDepth?.unit ?? dive.visibility?.unit ?? preferred
        temperatureUnit = dive.waterTemperature?.unit ?? preferredTemperature
        depthText = dive.maximumDepth.map { Self.format($0.value) } ?? ""
        durationText = dive.durationMinutes.map(String.init) ?? ""
        temperatureText = dive.waterTemperature.map { Self.format($0.value) } ?? ""
        visibilityText = dive.visibility.map { Self.format($0.value) } ?? ""
        notes = dive.notes ?? ""
    }

    /// Plausible ranges, in the entered units.
    static func depthRange(_ unit: DepthUnit) -> ClosedRange<Double> { unit == .metres ? 0.1...350 : 0.3...1150 }
    static func visibilityRange(_ unit: DepthUnit) -> ClosedRange<Double> { unit == .metres ? 0...100 : 0...330 }
    static func temperatureRange(_ unit: TemperatureUnit) -> ClosedRange<Double> { unit == .celsius ? -2...40 : 28...104 }
    static let durationRange = 1...600

    /// Field errors; empty when the form can be saved.
    var errors: [Field: String] {
        var errors: [Field: String] = [:]
        if let message = Self.check(depthText, Self.depthRange(depthUnit), "Maximum depth", depthUnit.symbol) { errors[.maximumDepth] = message }
        if let message = Self.check(visibilityText, Self.visibilityRange(depthUnit), "Visibility", depthUnit.symbol) { errors[.visibility] = message }
        if let message = Self.check(temperatureText, Self.temperatureRange(temperatureUnit), "Water temperature", temperatureUnit.symbol) { errors[.waterTemperature] = message }
        let duration = durationText.trimmingCharacters(in: .whitespaces)
        if !duration.isEmpty, Int(duration).map(Self.durationRange.contains) != true {
            errors[.duration] = "Duration must be a whole number of minutes from \(Self.durationRange.lowerBound) to \(Self.durationRange.upperBound)."
        }
        return errors
    }

    var isValid: Bool { errors.isEmpty }

    /// The dive to store. `existing` keeps its ID and creation time when editing.
    func makeDive(existing: Dive? = nil, calendar: Calendar = .current) -> Dive? {
        guard isValid else { return nil }
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        guard let localDate = LocalDate(year: day.year ?? 0, month: day.month ?? 0, day: day.day ?? 0) else { return nil }
        let time = calendar.dateComponents([.hour, .minute], from: startTime)
        let trimmedSite = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return Dive(
            id: existing?.id ?? UUID(), date: localDate,
            startTime: hasStartTime ? LocalTime(hour: time.hour ?? 0, minute: time.minute ?? 0) : nil,
            siteName: trimmedSite.isEmpty ? nil : trimmedSite, regionID: regionID,
            maximumDepth: Self.number(depthText).map { Depth(value: $0, unit: depthUnit) },
            durationMinutes: Int(durationText.trimmingCharacters(in: .whitespaces)),
            waterTemperature: Self.number(temperatureText).map { Temperature(value: $0, unit: temperatureUnit) },
            visibility: Self.number(visibilityText).map { Distance(value: $0, unit: depthUnit) },
            notes: trimmedNotes.isEmpty ? nil : notes,
            createdAt: existing?.createdAt ?? Date())
    }

    /// "18", "18.5" or "18,5"; nil for blank.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    static func check(_ text: String, _ range: ClosedRange<Double>, _ name: String, _ unit: String) -> String? {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let value = number(text) else { return "\(name) must be a number." }
        guard range.contains(value) else { return "\(name) must be between \(format(range.lowerBound)) and \(format(range.upperBound)) \(unit)." }
        return nil
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
    }
}

// MARK: Editing a sighting

/// The edit form for one sighting's notes, depth and dive. Blank depth is unknown; "0" is a
/// real depth (at the surface). Depth keeps the units it was stored in, so nothing is converted.
struct SightingEditForm: Equatable, Sendable {
    var notes: String
    var depthText: String
    var depthUnit: DepthUnit
    var diveID: UUID?

    init(editing sighting: SavedIdentification, preferredUnit: DepthUnit) {
        notes = sighting.notes ?? ""
        depthText = sighting.depth.map { DiveForm.format($0.value) } ?? ""
        depthUnit = sighting.depth?.unit ?? preferredUnit
        diveID = sighting.diveID
    }

    /// Zero (the surface) up to the dive form's plausible maximum, in the entered units.
    static func depthRange(_ unit: DepthUnit) -> ClosedRange<Double> { 0...DiveForm.depthRange(unit).upperBound }

    var depthError: String? { DiveForm.check(depthText, Self.depthRange(depthUnit), "Depth", depthUnit.symbol) }
    var isValid: Bool { depthError == nil }

    /// What to store, or nil while the depth is invalid. Blank notes are stored as none.
    var edit: SightingEdit? {
        guard isValid else { return nil }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return SightingEdit(notes: trimmedNotes.isEmpty ? nil : notes,
                            depth: DiveForm.number(depthText).map { Depth(value: $0, unit: depthUnit) },
                            diveID: diveID)
    }
}

/// Edit one saved sighting. A failed save keeps every edit and says why; Cancel saves nothing.
@MainActor @Observable
final class SightingEditorViewModel {
    /// The sighting as last stored.
    private(set) var sighting: SavedIdentification
    var form: SightingEditForm
    /// Dives to choose from, newest first.
    private(set) var dives: [Dive] = []
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private let repository: any DiveLogRepository

    init(sighting: SavedIdentification, repository: any DiveLogRepository, preferredUnit: DepthUnit) {
        self.sighting = sighting
        self.repository = repository
        form = SightingEditForm(editing: sighting, preferredUnit: preferredUnit)
    }

    /// Whether Save would change anything. Invalid input counts as a change, so it isn't lost.
    var hasChanges: Bool { form.edit.map { $0 != SightingEdit(sighting) } ?? true }
    var canSave: Bool { form.isValid && !isSaving }

    /// The dive the form names but the list doesn't have (the list couldn't load, or the dive is gone).
    var chosenDiveIsUnlisted: Bool { form.diveID.map { id in !dives.contains { $0.id == id } } ?? false }

    func loadDives() async {
        do { dives = try await repository.dives().map(\.dive) }
        catch { errorMessage = "Your dives couldn't be loaded. " + SavedIdentificationRepositoryError.message(for: error) }
    }

    /// The stored sighting, or nil when the save failed (the form keeps the edits).
    func save() async -> SavedIdentification? {
        guard let edit = form.edit, !isSaving else { return nil }
        isSaving = true
        defer { isSaving = false }
        do {
            let stored = try await repository.editSighting(id: sighting.id, edit)
            sighting = stored
            errorMessage = nil
            return stored
        } catch SavedIdentificationRepositoryError.diveNotFound {
            // The chosen dive was deleted while editing (the sighting itself is checked first).
            // Storage is unchanged; offer the dives that still exist, with No dive chosen.
            await loadDives()
            form.diveID = nil
            errorMessage = "The dive you chose no longer exists, so nothing was saved. The sighting is set to No dive here: choose a dive or keep No dive, then save again. Your other changes are kept."
        } catch {
            errorMessage = "Your changes weren't saved. " + SavedIdentificationRepositoryError.message(for: error) + " Your edits are still here."
        }
        return nil
    }
}

extension SightingEditorViewModel: Identifiable {}

// MARK: The Dive Log screen

/// Dives newest first, each with its sightings, then the sightings on no dive.
@MainActor @Observable
final class DiveLogViewModel {
    private(set) var dives: [DiveWithSightings] = []
    private(set) var unassigned: [SavedIdentification] = []
    private(set) var regionNames: [OfflineIdentificationPackID: String] = [:]
    private(set) var regionChoices: [OfflineIdentificationPackMetadata] = []
    private(set) var isLoading = true
    private(set) var isUpdating = false
    var errorMessage: String?
    private var retryAction: (@MainActor () async -> Void)?
    let repository: any SavedLogRepository
    private let catalog: (any MarineSpeciesCatalogRepository)?
    /// Import Backup; a successful import reloads this log.
    let importer: DiveLogImportViewModel

    init(repository: any SavedLogRepository, catalog: (any MarineSpeciesCatalogRepository)? = nil) {
        self.repository = repository
        self.catalog = catalog
        importer = DiveLogImportViewModel(repository: repository)
        importer.onImported = { [weak self] in await self?.load() }
    }

    var isEmpty: Bool { dives.isEmpty && unassigned.isEmpty }
    var sightingCount: Int { dives.reduce(0) { $0 + $1.sightings.count } + unassigned.count }
    /// Any dive or sighting: a log of dives alone exports too (JSON keeps empty dives).
    var canExport: Bool { !isEmpty }

    func regionName(_ id: OfflineIdentificationPackID?) -> String? { id.map { regionNames[$0] ?? $0.rawValue } }
    func dive(_ id: UUID) -> DiveWithSightings? { dives.first { $0.dive.id == id } }

    /// Keeps the confirmed lists when a reload fails (as the saved list did).
    func load() async {
        defer { isLoading = false }
        if regionChoices.isEmpty, let packs = try? await catalog?.availablePacks() {
            regionChoices = packs
            regionNames = Dictionary(packs.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        }
        do {
            let dives = try await repository.dives()
            let all = try await repository.fetchAll()
            self.dives = dives
            unassigned = all.filter { $0.diveID == nil }
            errorMessage = nil
            retryAction = nil
        } catch {
            fail(error) { [weak self] in await self?.load() }
        }
    }

    func retry() async { if let retryAction { await retryAction() } else { await load() } }

    @discardableResult
    func save(_ form: DiveForm, editing existing: Dive? = nil) async -> Dive? {
        guard let dive = form.makeDive(existing: existing) else { return nil }
        return await perform({ [weak self] in await self?.save(form, editing: existing) }) {
            existing == nil ? try await self.repository.createDive(dive) : try await self.repository.updateDive(dive)
        }
    }

    func delete(_ dive: Dive, sightings: DiveDeletion = .keepUnassigned) async {
        _ = await perform({ [weak self] in await self?.delete(dive, sightings: sightings) }) {
            try await self.repository.deleteDive(id: dive.id, sightings: sightings)
        }
    }

    func assign(_ sightingIDs: [UUID], to dive: Dive) async {
        _ = await perform({ [weak self] in await self?.assign(sightingIDs, to: dive) }) {
            try await self.repository.assign(sightingIDs: sightingIDs, toDive: dive.id)
        }
    }

    func unassign(_ sightingIDs: [UUID]) async {
        _ = await perform({ [weak self] in await self?.unassign(sightingIDs) }) {
            try await self.repository.unassign(sightingIDs: sightingIDs)
        }
    }

    func remove(_ sighting: SavedIdentification) async {
        _ = await perform({ [weak self] in await self?.remove(sighting) }) { try await self.repository.remove(id: sighting.id) }
    }

    private func perform<T>(_ retry: @escaping @MainActor () async -> Void, _ body: () async throws -> T) async -> T? {
        guard !isUpdating else { return nil }
        isUpdating = true
        do {
            let value = try await body()
            isUpdating = false
            await load()
            return value
        } catch {
            isUpdating = false
            fail(error, retry: retry)
            return nil
        }
    }

    private func fail(_ error: Error, retry: @escaping @MainActor () async -> Void) {
        errorMessage = SavedIdentificationRepositoryError.message(for: error)
        retryAction = retry
    }
}

// MARK: Export

/// The Dive Log as CSV (one row per sighting with its dive's fields) or JSON (everything).
struct DiveLogExport: Sendable {
    enum Format: String, CaseIterable, Sendable { case csv, json }

    let dives: [DiveWithSightings]
    /// Sightings on no dive; only in a whole-log export.
    let unassigned: [SavedIdentification]
    let regionNames: [OfflineIdentificationPackID: String]
    let exportedAt: Date

    static func wholeLog(_ dives: [DiveWithSightings], unassigned: [SavedIdentification],
                         regionNames: [OfflineIdentificationPackID: String] = [:], now: Date = Date()) -> Self {
        Self(dives: dives, unassigned: unassigned, regionNames: regionNames, exportedAt: now)
    }

    static func oneDive(_ dive: DiveWithSightings, regionNames: [OfflineIdentificationPackID: String] = [:], now: Date = Date()) -> Self {
        Self(dives: [dive], unassigned: [], regionNames: regionNames, exportedAt: now)
    }

    var rowCount: Int { dives.reduce(0) { $0 + $1.sightings.count } + unassigned.count }

    // MARK: CSV

    static let columns = [
        "dive_id", "dive_date", "dive_start_time", "dive_site", "dive_region", "dive_max_depth", "dive_max_depth_unit",
        "dive_duration_minutes", "dive_water_temperature", "dive_water_temperature_unit", "dive_visibility", "dive_visibility_unit",
        "dive_notes", "sighting_id", "identified_at", "common_name", "scientific_name", "sighting_depth", "sighting_depth_unit",
        "sighting_notes", "saved_from", "match_strength", "observation_description", "photo_recognizer", "photo_reference",
    ]

    /// fieldGuide, search, photo, or photoPlaceholder (a test recognizer's placeholder result).
    static func savedFrom(_ sighting: SavedIdentification) -> String {
        if sighting.isFromFieldGuide { return "fieldGuide" }
        guard sighting.isFromPhoto else { return "search" }
        return sighting.isPlaceholderPhotoResult ? "photoPlaceholder" : "photo"
    }

    func csv() -> String {
        var lines = [Self.columns.joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        func row(_ dive: Dive?, _ sighting: SavedIdentification) -> String {
            let values: [String] = [
                dive?.id.uuidString ?? "", dive?.date.description ?? "", dive?.startTime?.description ?? "", dive?.siteName ?? "",
                dive?.regionID.map { regionNames[$0] ?? $0.rawValue } ?? "",
                dive?.maximumDepth.map { DiveForm.format($0.value) } ?? "", dive?.maximumDepth?.unit.rawValue ?? "",
                dive?.durationMinutes.map(String.init) ?? "",
                dive?.waterTemperature.map { DiveForm.format($0.value) } ?? "", dive?.waterTemperature?.unit.rawValue ?? "",
                dive?.visibility.map { DiveForm.format($0.value) } ?? "", dive?.visibility?.unit.rawValue ?? "",
                dive?.notes ?? "",
                sighting.id.uuidString, iso.string(from: sighting.identifiedAt), sighting.species.commonName, sighting.species.scientificName,
                sighting.depth.map { DiveForm.format($0.value) } ?? "", sighting.depth?.unit.rawValue ?? "",
                sighting.notes ?? "", Self.savedFrom(sighting),
                sighting.isFromFieldGuide ? "" : sighting.matchStrength.rawValue, sighting.observationDescription,
                sighting.photoRecognizer.map { "\($0.recognizerID) \($0.recognizerVersion)" } ?? "",
                sighting.photoEvidence?.referenceFileName ?? sighting.photoEvidence?.referenceID ?? "",
            ]
            return values.map(Self.escape).joined(separator: ",")
        }
        for entry in dives { for sighting in entry.sightings { lines.append(row(entry.dive, sighting)) } }
        for sighting in unassigned { lines.append(row(nil, sighting)) }
        return lines.joined(separator: "\r\n") + "\r\n"  // RFC 4180 line endings
    }

    /// RFC 4180: a field with a comma, quote, or line break is quoted, quotes doubled. A field
    /// a spreadsheet would run as a formula (=, +, -, @ first) gets a leading apostrophe,
    /// unless it is a plain number such as a -1 °C water temperature.
    static func escape(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@".contains(first), !isPlainNumber(value) { value = "'" + value }
        // isNewline also catches "\r\n", which Swift treats as one character.
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func isPlainNumber(_ value: String) -> Bool {
        value.range(of: #"^[-+]?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil
    }

    // MARK: JSON

    struct Document: Codable, Equatable, Sendable {
        struct DiveEntry: Codable, Equatable, Sendable { let dive: Dive; let sightings: [SavedIdentification] }
        let schemaVersion: Int
        let format: String
        let exportedAt: Date
        let dives: [DiveEntry]
        let unassignedSightings: [SavedIdentification]
    }

    var document: Document {
        Document(schemaVersion: 1, format: "diveid-dive-log", exportedAt: exportedAt,
                 dives: dives.map { .init(dive: $0.dive, sightings: $0.sightings) }, unassignedSightings: unassigned)
    }

    /// ISO 8601 with fractional seconds, so times round-trip (plain .iso8601 drops them).
    static func isoFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = isoFormatter().date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an ISO 8601 date: \(text)"))
            }
            return date
        }
        return decoder
    }()

    /// The export's encoding: ISO 8601 dates with milliseconds, sorted keys. Import compares
    /// records in this form, so a record that only went through an export still matches.
    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.isoFormatter().string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    func json() throws -> Data { try Self.jsonEncoder().encode(document) }

    /// Writes the chosen format to a temporary file for the share sheet.
    func write(_ format: Format, name: String, directory: URL = ExportFiles.directory()) throws -> URL {
        ExportFiles.removeAll(in: directory)
        let day = ISO8601DateFormatter.string(from: exportedAt, timeZone: .current, formatOptions: [.withFullDate])
        let safe = name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let url = directory.appendingPathComponent("DiveID-\(safe.isEmpty ? "dive-log" : safe)-\(day).\(format.rawValue)")
        switch format {
        case .csv: try Data(csv().utf8).write(to: url, options: .atomic)
        case .json: try json().write(to: url, options: .atomic)
        }
        return url
    }
}
