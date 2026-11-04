import Foundation
import Observation

// MARK: Reading and checking a backup

/// Restoring a Dive Log JSON export (format "diveid-dive-log"). The whole file is checked
/// before anything is shown or written; a file with any problem imports nothing.
enum DiveLogBackup {
    static let format = "diveid-dive-log"
    /// Export schema versions this app can import.
    static let supportedSchemaVersions: ClosedRange<Int> = 1...1
    /// Larger files are refused before they are read in full.
    static let maximumFileBytes = 50 * 1024 * 1024

    /// Why a file can't be imported, worded for the diver. Nothing has been changed.
    struct Problem: Error, Equatable, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The checked backup, or the first problem found.
    static func read(_ data: Data) throws -> DiveLogExport.Document {
        guard !data.isEmpty else { throw Problem(message: "The file is empty. Choose a JSON file exported from Dive Log → Export → JSON.") }
        try checkSize(data.count)
        struct Header: Decodable { let format: String?; let schemaVersion: Int? }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw Problem(message: "This file isn't a Dive ID backup: it isn't readable JSON. Choose a JSON file exported from Dive Log → Export → JSON.")
        }
        guard header.format == format else {
            throw Problem(message: "This file isn't a Dive ID dive log backup. Choose a JSON file exported from Dive Log → Export → JSON (CSV exports can't be imported).")
        }
        guard let version = header.schemaVersion else { throw Problem(message: "The backup has no version number, so it can't be read safely. Nothing was imported.") }
        guard supportedSchemaVersions.contains(version) else {
            throw Problem(message: version > supportedSchemaVersions.upperBound
                ? "This backup was made by a newer version of Dive ID (backup version \(version)). Update Dive ID, then import it again."
                : "Backup version \(version) isn't supported. Nothing was imported.")
        }
        let document: DiveLogExport.Document
        do { document = try DiveLogExport.jsonDecoder.decode(DiveLogExport.Document.self, from: data) }
        catch let error as DecodingError { throw Problem(message: "The backup is incomplete or damaged: \(describe(error)) Nothing was imported.") }
        try validate(document)
        return document
    }

    static func checkSize(_ bytes: Int) throws {
        guard bytes <= maximumFileBytes else {
            let megabytes = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            throw Problem(message: "The file is \(megabytes); backups up to \(maximumFileBytes / 1024 / 1024) MB can be imported. Export a single dive, or a smaller log, instead.")
        }
    }

    /// Every rule a store applies, plus the backup's own structure: unique IDs, each sighting
    /// filed under the dive it names, valid depths and dives, and plain picture file names.
    static func validate(_ document: DiveLogExport.Document) throws {
        var diveIDs = Set<UUID>()
        for entry in document.dives {
            let dive = entry.dive
            guard diveIDs.insert(dive.id).inserted else { throw Problem(message: "Dive \(dive.id.uuidString) appears twice in the backup. Nothing was imported.") }
            if let reason = dive.invalidReason { throw Problem(message: "The dive on \(dive.date) can't be imported: \(reason) Nothing was imported.") }
        }
        var sightingIDs = Set<UUID>()
        func check(_ sighting: SavedIdentification, filedUnder diveID: UUID?) throws {
            let name = sighting.species.commonName
            guard sightingIDs.insert(sighting.id).inserted else { throw Problem(message: "The \(name) sighting \(sighting.id.uuidString) appears twice in the backup. Nothing was imported.") }
            if sighting.diveID != diveID {
                let reason: String
                switch (sighting.diveID, diveID) {
                case (let named?, _) where !diveIDs.contains(named): reason = "it names a dive that isn't in the backup"
                case (nil, _?): reason = "it is listed under a dive but names no dive"
                case (_?, nil): reason = "it is listed as on no dive but names a dive"
                default: reason = "it is listed under one dive but names another"
                }
                throw Problem(message: "The \(name) sighting can't be imported: \(reason). Nothing was imported.")
            }
            if let depth = sighting.depth, !depth.isValid { throw Problem(message: "The \(name) sighting has a depth below zero. Nothing was imported.") }
            let pictures = [sighting.species.bundledImage?.fileName, sighting.photoEvidence?.referenceFileName].compactMap { $0 }
            if let evidence = sighting.photoEvidence, evidence.referenceID.isEmpty { throw Problem(message: "The \(name) sighting's photo match has no reference. Nothing was imported.") }
            guard pictures.allSatisfy(isPlainFileName) else { throw Problem(message: "The \(name) sighting names a picture with an invalid file name. Nothing was imported.") }
        }
        for entry in document.dives { for sighting in entry.sightings { try check(sighting, filedUnder: entry.dive.id) } }
        for sighting in document.unassignedSightings { try check(sighting, filedUnder: nil) }
    }

    /// A picture is named, never embedded: only a plain file name is accepted.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 255 && !name.contains("/") && !name.contains("\\") && name != "." && name != ".." && !name.hasPrefix(".")
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context, _ key: CodingKey? = nil) -> String {
            let keys = context.codingPath + (key.map { [$0] } ?? [])
            let text = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return text.hasPrefix(".") ? String(text.dropFirst()) : (text.isEmpty ? "the top level" : text)
        }
        switch error {
        case .keyNotFound(let key, let context): return "the required field \(path(context, key)) is missing."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)) has the wrong kind of value."
        case .dataCorrupted(let context): return "\(path(context)) is not valid (\(context.debugDescription))."
        @unknown default: return "it could not be read."
        }
    }
}

// MARK: What an import would do

/// The outcome of importing a checked backup into the current log. Records are matched only
/// by ID: different IDs are never merged, however alike. Existing records always win.
struct DiveLogImportPlan: Equatable, Sendable {
    struct Conflict: Hashable, Identifiable, Sendable {
        enum Kind: String, Sendable { case dive, sighting }
        let kind: Kind
        let id: UUID
        let title: String
        let reason: String
    }

    var newDives: [Dive] = []
    var newSightings: [SavedIdentification] = []
    /// Identical to a record already in the log: skipped.
    var alreadyPresentDives = 0
    var alreadyPresentSightings = 0
    /// Not imported; the existing record is kept as it is.
    var conflicts: [Conflict] = []
    /// New sightings that name a catalogue picture or a matched reference photo. Backups
    /// carry no image data; these show only if this app version has the picture.
    var newSightingsWithPictures = 0
    var newPhotoSearchSightings = 0

    var hasChanges: Bool { !newDives.isEmpty || !newSightings.isEmpty }
    var alreadyPresent: Int { alreadyPresentDives + alreadyPresentSightings }

    static func make(_ document: DiveLogExport.Document, existing store: SavedStore) -> DiveLogImportPlan {
        var plan = DiveLogImportPlan()
        let dives = Dictionary(store.dives.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sightings = Dictionary(store.identifications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var blockedDives = Set<UUID>()
        for entry in document.dives {
            let dive = entry.dive
            if let existing = dives[dive.id] {
                if same(existing, dive) { plan.alreadyPresentDives += 1 }
                else {
                    blockedDives.insert(dive.id)
                    plan.conflicts.append(.init(kind: .dive, id: dive.id, title: DiveLogImportPlan.title(dive),
                                                reason: "A dive with this ID is already in your log with different details. Yours is kept."))
                }
            } else {
                plan.newDives.append(dive)
            }
        }
        // Rules a store keeps when saving: one save per search and species, one field-guide
        // bookmark per species. A backup record that would break them is reported, not merged.
        var kept = store.identifications
        for sighting in document.dives.flatMap(\.sightings) + document.unassignedSightings {
            let title = sighting.species.commonName
            if let existing = sightings[sighting.id] {
                if same(existing, sighting) { plan.alreadyPresentSightings += 1 }
                else { plan.conflicts.append(.init(kind: .sighting, id: sighting.id, title: title,
                                                   reason: "A sighting with this ID is already in your log with different details. Yours is kept.")) }
                continue
            }
            if let diveID = sighting.diveID, blockedDives.contains(diveID) {
                plan.conflicts.append(.init(kind: .sighting, id: sighting.id, title: title,
                                            reason: "Its dive conflicts with a dive in your log, so it isn't added to a dive it doesn't belong to."))
                continue
            }
            if kept.contains(where: { SavedIdentificationFile.isSame($0, sighting) }) {
                plan.conflicts.append(.init(kind: .sighting, id: sighting.id, title: title, reason: sighting.isFieldGuideBookmark
                    ? "This species is already saved from the field guide in your log. Yours is kept."
                    : "This search's match is already saved in your log under another ID. Yours is kept."))
                continue
            }
            kept.append(sighting)
            plan.newSightings.append(sighting)
            if sighting.species.bundledImage != nil || sighting.photoEvidence != nil { plan.newSightingsWithPictures += 1 }
            if sighting.isFromPhoto { plan.newPhotoSearchSightings += 1 }
        }
        return plan
    }

    /// Equal as exported: dates to the millisecond, as a backup stores them.
    static func same<T: Encodable>(_ lhs: T, _ rhs: T) -> Bool {
        let encoder = DiveLogExport.jsonEncoder()
        guard let left = try? encoder.encode(lhs), let right = try? encoder.encode(rhs) else { return false }
        return left == right
    }

    static func title(_ dive: Dive) -> String { [dive.siteName ?? "Unnamed site", dive.date.description].joined(separator: " · ") }
}

extension SavedStore {
    /// Adds the backup's new dives and sightings in one change, planned against the store as
    /// it is now (it may have changed since the preview). Nothing existing is altered.
    mutating func importBackup(_ document: DiveLogExport.Document) throws -> DiveLogImportPlan {
        try DiveLogBackup.validate(document)
        let plan = DiveLogImportPlan.make(document, existing: self)
        dives.append(contentsOf: plan.newDives)
        identifications.append(contentsOf: plan.newSightings)
        return plan
    }
}

// MARK: The import screen's model

/// A checked backup and what importing it would do, shown before anything is written.
struct DiveLogImportPreview: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let document: DiveLogExport.Document
    let plan: DiveLogImportPlan
}

/// Import Backup: read and check the file, preview, then import on the diver's say-so.
@MainActor @Observable
final class DiveLogImportViewModel {
    private(set) var preview: DiveLogImportPreview?
    private(set) var isWorking = false
    /// A file that couldn't be read or checked; nothing was changed.
    var problem: String?
    /// A failed import; the preview stays open to try again.
    private(set) var importError: String?
    /// After a successful import.
    var result: String?
    private let repository: any SavedLogRepository
    /// Runs after a successful import, to refresh the screens showing the log.
    var onImported: @MainActor () async -> Void

    init(repository: any SavedLogRepository, onImported: @escaping @MainActor () async -> Void = {}) {
        self.repository = repository
        self.onImported = onImported
    }

    /// From the system file importer. Cancelling it is not an error.
    func fileChosen(_ result: Result<[URL], Error>) async {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            await open(url)
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled { return }
            problem = "The file couldn't be opened. \(error.localizedDescription)"
        }
    }

    func open(_ url: URL) async {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize { try DiveLogBackup.checkSize(size) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            await prepare(data, fileName: url.lastPathComponent)
        } catch let problem as DiveLogBackup.Problem {
            self.problem = problem.message
        } catch {
            problem = "The file couldn't be read. If it's in iCloud Drive, download it first, then try again."
        }
    }

    func prepare(_ data: Data, fileName: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let document = try DiveLogBackup.read(data)
            let store = SavedStore(identifications: try await repository.fetchAll(), dives: try await repository.dives().map(\.dive))
            preview = DiveLogImportPreview(fileName: fileName, document: document, plan: .make(document, existing: store))
            problem = nil
            importError = nil
        } catch let problem as DiveLogBackup.Problem {
            self.problem = problem.message
        } catch {
            problem = "Your dive log couldn't be read to compare with the backup. " + SavedIdentificationRepositoryError.message(for: error)
        }
    }

    /// The diver chose Import. A failure leaves the log as it was and the preview open.
    func confirm() async {
        guard let preview, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let applied = try await repository.importBackup(preview.document)
            self.preview = nil
            importError = nil
            result = Self.summary(applied)
            await onImported()
        } catch {
            importError = "Nothing was imported; your dive log is unchanged. " + SavedIdentificationRepositoryError.message(for: error)
        }
    }

    func cancel() { preview = nil; importError = nil }

    static func summary(_ plan: DiveLogImportPlan) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts = ["Imported \(count(plan.newDives.count, "dive", "dives")) and \(count(plan.newSightings.count, "sighting", "sightings"))."]
        if plan.alreadyPresent > 0 { parts.append("Skipped \(count(plan.alreadyPresent, "record", "records")) already in your log.") }
        if !plan.conflicts.isEmpty { parts.append("\(count(plan.conflicts.count, "conflict", "conflicts")) kept your existing records.") }
        return parts.joined(separator: " ")
    }
}
