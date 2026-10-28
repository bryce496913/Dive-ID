import XCTest
@testable import DiveID

/// The Dive Log screens' logic: the dive form, the units setting, assigning and deleting,
/// "Add to dive" after saving, and the CSV/JSON export.
@MainActor
final class DiveLogScreenTests: XCTestCase {
    private let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func sighting(_ name: String, notes: String? = nil, at time: TimeInterval = 800_000_000) -> SavedIdentification {
        let species = Species(id: UUID(), commonName: name, scientificName: "\(name) scientifica", summary: "", visualCharacteristics: [],
                              habitat: "", geographicRange: "", imageAssetName: nil)
        var match = IdentificationMatch(id: species.id, species: species, rank: 1, score: 0.8, scoreKind: .relativeMatch, strength: .good,
                                        explanation: "Synthetic")
        match.sourceSessionID = UUID()
        return SavedIdentification(match: match, identifiedAt: Date(timeIntervalSinceReferenceDate: time), notes: notes)
    }

    // MARK: Form: units and ranges

    func testOnlyTheDateIsRequired() throws {
        let form = DiveForm(now: day(2026, 3, 14), depthUnit: .metres, temperatureUnit: .celsius)
        XCTAssertTrue(form.isValid)
        let dive = try XCTUnwrap(form.makeDive(calendar: calendar))
        XCTAssertEqual(dive.date.description, "2026-03-14")
        XCTAssertNil(dive.startTime)
        XCTAssertNil(dive.siteName)
        XCTAssertNil(dive.maximumDepth)
        XCTAssertNil(dive.durationMinutes)
        XCTAssertNil(dive.waterTemperature)
        XCTAssertNil(dive.visibility)
        XCTAssertNil(dive.notes)
    }

    func testDepthIsCheckedAndStoredInTheUnitsItWasEnteredIn() throws {
        var form = DiveForm(now: day(2026, 3, 14), depthUnit: .metres, temperatureUnit: .celsius)
        for (text, valid) in [("18,5", true), ("350", true), ("351", false), ("0", false), ("-2", false), ("deep", false)] {
            form.depthText = text
            XCTAssertEqual(form.errors[.maximumDepth] == nil, valid, "\(text) m")
        }
        form.depthUnit = .feet
        for (text, valid) in [("1150", true), ("1151", false), ("60", true)] {
            form.depthText = text
            XCTAssertEqual(form.errors[.maximumDepth] == nil, valid, "\(text) ft")
        }
        let dive = try XCTUnwrap(form.makeDive(calendar: calendar))
        XCTAssertEqual(dive.maximumDepth, Depth(value: 60, unit: .feet), "stored as entered, not converted")
        form.depthText = "18,5"
        form.depthUnit = .metres
        XCTAssertEqual(form.makeDive(calendar: calendar)?.maximumDepth, Depth(value: 18.5, unit: .metres))
        form.depthText = "deep"
        XCTAssertNil(form.makeDive(calendar: calendar), "an invalid form makes no dive")
        XCTAssertEqual(form.errors[.maximumDepth], "Maximum depth must be a number.")
    }

    func testTemperatureVisibilityAndDurationRanges() {
        var form = DiveForm(now: day(2026, 3, 14), depthUnit: .metres, temperatureUnit: .celsius)
        for (text, valid) in [("-2", true), ("40", true), ("41", false), ("27.5", true)] {
            form.temperatureText = text
            XCTAssertEqual(form.errors[.waterTemperature] == nil, valid, "\(text) °C")
        }
        form.temperatureUnit = .fahrenheit
        for (text, valid) in [("80", true), ("27", false), ("105", false)] {
            form.temperatureText = text
            XCTAssertEqual(form.errors[.waterTemperature] == nil, valid, "\(text) °F")
        }
        for (text, valid) in [("0", true), ("100", true), ("101", false)] {
            form.visibilityText = text
            XCTAssertEqual(form.errors[.visibility] == nil, valid, "\(text) m visibility")
        }
        for (text, valid) in [("45", true), ("0", false), ("601", false), ("45.5", false), ("", true)] {
            form.durationText = text
            XCTAssertEqual(form.errors[.duration] == nil, valid, "\(text) minutes")
        }
    }

    func testEditingKeepsIDCreationTimeAndStoredUnits() throws {
        var original = Dive(date: try XCTUnwrap(LocalDate("2026-03-14")), startTime: LocalTime("09:30"), siteName: "Salt Pier",
                            regionID: .tropicalAtlantic, maximumDepth: Depth(value: 70, unit: .feet), durationMinutes: 52,
                            waterTemperature: Temperature(value: 81, unit: .fahrenheit), visibility: Distance(value: 60, unit: .feet),
                            notes: "Current", createdAt: Date(timeIntervalSinceReferenceDate: 1000))
        original.updatedAt = original.createdAt
        var form = DiveForm(editing: original, depthUnit: .metres, temperatureUnit: .celsius, calendar: calendar)
        XCTAssertEqual(form.depthUnit, .feet, "the stored units, not the setting")
        XCTAssertEqual(form.depthText, "70")
        XCTAssertTrue(form.hasStartTime)
        form.notes = "Strong current"
        let edited = try XCTUnwrap(form.makeDive(existing: original, calendar: calendar))
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.startTime?.description, "09:30")
        XCTAssertEqual(edited.date, original.date)
        XCTAssertEqual(edited.maximumDepth, original.maximumDepth)
        XCTAssertEqual(edited.waterTemperature, original.waterTemperature)
        XCTAssertEqual(edited.notes, "Strong current")
    }

    func testUnitsSettingDefaultsFromTheLocaleAndIsRemembered() {
        let defaults = UserDefaults(suiteName: "DiveLogScreenTests-\(UUID())")!
        XCTAssertEqual(MeasurementPreference(defaults: defaults, locale: Locale(identifier: "en_US")).depthUnit, .feet)
        XCTAssertEqual(MeasurementPreference(defaults: defaults, locale: Locale(identifier: "en_GB")).depthUnit, .metres)
        XCTAssertEqual(MeasurementPreference(defaults: defaults, locale: Locale(identifier: "fr_FR")).temperatureUnit, .celsius)
        MeasurementPreference(defaults: defaults, locale: Locale(identifier: "en_US")).depthUnit = .metres
        XCTAssertEqual(MeasurementPreference(defaults: defaults, locale: Locale(identifier: "en_US")).depthUnit, .metres, "the setting wins")
    }

    // MARK: Dive Log: assigning, unassigning, deleting, failures

    func testAssigningUnassigningAndDeletingThroughTheDiveLog() async throws {
        let first = sighting("Queen Angelfish"), second = sighting("Spotted Eagle Ray", at: 800_000_100)
        let repository = InMemorySavedIdentificationRepository(initial: [first, second])
        let log = DiveLogViewModel(repository: repository)
        await log.load()
        XCTAssertEqual(log.unassigned.count, 2)
        let created = await log.save(DiveForm(now: day(2026, 3, 14), depthUnit: .metres, temperatureUnit: .celsius))
        let dive = try XCTUnwrap(created)
        await log.assign([first.id, second.id], to: dive)
        XCTAssertEqual(log.dive(dive.id)?.sightings.map(\.id), [second.id, first.id], "newest first")
        XCTAssertTrue(log.unassigned.isEmpty)
        await log.unassign([second.id])
        XCTAssertEqual(log.unassigned.map(\.id), [second.id])
        await log.delete(dive)
        XCTAssertTrue(log.dives.isEmpty)
        XCTAssertEqual(Set(log.unassigned.map(\.id)), [first.id, second.id], "keeping sightings is the default")

        let createdAgain = await log.save(DiveForm(now: day(2026, 3, 15), depthUnit: .metres, temperatureUnit: .celsius))
        let again = try XCTUnwrap(createdAgain)
        await log.assign([first.id], to: again)
        await log.delete(again, sightings: .deleteSightings)
        XCTAssertEqual(log.unassigned.map(\.id), [second.id])
        XCTAssertEqual(log.sightingCount, 1)
    }

    func testAFailedChangeShowsAnErrorAndRetryApplies() async throws {
        let item = sighting("Queen Angelfish")
        let repository = FlakyLogRepository(base: InMemorySavedIdentificationRepository(initial: [item]))
        let log = DiveLogViewModel(repository: repository)
        await log.load()
        await repository.setFailing(true)
        let saved = await log.save(DiveForm(now: day(2026, 3, 14), depthUnit: .metres, temperatureUnit: .celsius))
        XCTAssertNil(saved)
        XCTAssertNotNil(log.errorMessage)
        XCTAssertTrue(log.dives.isEmpty)
        await repository.setFailing(false)
        await log.retry()
        XCTAssertNil(log.errorMessage)
        XCTAssertEqual(log.dives.count, 1, "retry repeats the failed change")
        XCTAssertEqual(log.unassigned.map(\.id), [item.id])
    }

    // MARK: Add to dive after saving

    func testSavingOffersTodaysDiveAndSkipLeavesItUnassigned() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let today = Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: today)
        let todaysDive = try await repository.createDive(Dive(date: try XCTUnwrap(LocalDate(year: parts.year!, month: parts.month!, day: parts.day!)), siteName: "House reef"))
        let older = try await repository.createDive(Dive(date: try XCTUnwrap(LocalDate("2020-01-01"))))
        let item = sighting("Queen Angelfish")
        let page = SpeciesDetailViewModel(species: item.species, match: item.match, repository: repository)
        await page.toggleSaved()
        let offer = try XCTUnwrap(page.addToDiveOffer)
        XCTAssertEqual(offer.todaysDive?.id, todaysDive.id)
        XCTAssertEqual(Set(offer.dives.map(\.id)), [todaysDive.id, older.id])
        page.skipAddToDive()
        XCTAssertNil(page.addToDiveOffer)
        let saved = try await repository.fetchAll()
        XCTAssertNil(saved.first?.diveID, "skip changes nothing")

        let other = sighting("Spotted Eagle Ray")
        let second = SpeciesDetailViewModel(species: other.species, match: other.match, repository: repository)
        await second.toggleSaved()
        await second.addToDive(todaysDive)
        XCTAssertNil(second.addToDiveOffer)
        let dives = try await repository.dives()
        XCTAssertEqual(dives.first { $0.dive.id == todaysDive.id }?.sightings.map(\.species.commonName), ["Spotted Eagle Ray"])
    }

    func testSavingCanCreateANewDiveForTheSighting() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let item = sighting("Queen Angelfish")
        let page = SpeciesDetailViewModel(species: item.species, match: item.match, repository: repository)
        await page.toggleSaved()
        XCTAssertNil(page.addToDiveOffer?.todaysDive)
        var form = DiveForm(now: day(2026, 3, 14), depthUnit: .metres, temperatureUnit: .celsius)
        form.siteName = "Salt Pier"
        let added = await page.createDiveAndAdd(form)
        XCTAssertTrue(added)
        let dives = try await repository.dives()
        XCTAssertEqual(dives.map(\.dive.siteName), ["Salt Pier"])
        XCTAssertEqual(dives.first?.sightings.map(\.id), [page.savedIdentificationID].compactMap { $0 })
    }

    func testAStoreWithoutDivesOffersNothing() async throws {
        let item = sighting("Queen Angelfish")
        let page = SpeciesDetailViewModel(species: item.species, match: item.match, repository: SightingsOnlyRepository())
        await page.toggleSaved()
        XCTAssertTrue(page.isSaved)
        XCTAssertNil(page.addToDiveOffer)
    }

    // MARK: Export

    func testCSVColumnOrderIsFixed() {
        XCTAssertEqual(DiveLogExport.columns, [
            "dive_id", "dive_date", "dive_start_time", "dive_site", "dive_region", "dive_max_depth", "dive_max_depth_unit",
            "dive_duration_minutes", "dive_water_temperature", "dive_water_temperature_unit", "dive_visibility", "dive_visibility_unit",
            "dive_notes", "sighting_id", "identified_at", "common_name", "scientific_name", "sighting_depth", "sighting_depth_unit",
            "sighting_notes", "saved_from", "match_strength", "observation_description",
        ])
        let header = DiveLogExport.wholeLog([], unassigned: []).csv().components(separatedBy: "\r\n").first
        XCTAssertEqual(header, DiveLogExport.columns.joined(separator: ","))
    }

    func testCSVEscapesCommasQuotesNewlinesAndFormulas() throws {
        XCTAssertEqual(DiveLogExport.escape("plain"), "plain")
        XCTAssertEqual(DiveLogExport.escape("a, b"), "\"a, b\"")
        XCTAssertEqual(DiveLogExport.escape("the \"big\" one"), "\"the \"\"big\"\" one\"")
        XCTAssertEqual(DiveLogExport.escape("line one\nline two"), "\"line one\nline two\"")
        XCTAssertEqual(DiveLogExport.escape("cr\r\nlf"), "\"cr\r\nlf\"")
        XCTAssertEqual(DiveLogExport.escape("=SUM(A1)"), "'=SUM(A1)")
        XCTAssertEqual(DiveLogExport.escape("-3 m"), "'-3 m")
        XCTAssertEqual(DiveLogExport.escape("-1"), "-1", "negative numbers stay numbers")
        XCTAssertEqual(DiveLogExport.escape("-1.5"), "-1.5")
        XCTAssertEqual(DiveLogExport.escape("+2"), "+2")
        XCTAssertEqual(DiveLogExport.escape("-1+A1"), "'-1+A1")

        var item = sighting("Queen Angelfish", notes: "Two of them, \"huge\"\nnear the wall")
        item.depth = Depth(value: 12.5, unit: .metres)
        var dive = Dive(date: try XCTUnwrap(LocalDate("2026-03-14")), startTime: LocalTime("09:30"), siteName: "Salt Pier, Bonaire",
                        regionID: .tropicalAtlantic, maximumDepth: Depth(value: 21, unit: .metres), durationMinutes: 52,
                        waterTemperature: Temperature(value: 27, unit: .celsius), visibility: Distance(value: 60, unit: .feet))
        dive.notes = nil
        let loose = sighting("Spotted Eagle Ray")
        let export = DiveLogExport.wholeLog([DiveWithSightings(dive: dive, sightings: [item])], unassigned: [loose],
                                            regionNames: [.tropicalAtlantic: "Tropical Atlantic Regions"])
        XCTAssertEqual(export.rowCount, 2)
        let csv = export.csv()
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        let rows = Self.parseCSV(csv)
        XCTAssertEqual(rows.count, 3, "header plus one row per sighting")
        XCTAssertTrue(rows.allSatisfy { $0.count == DiveLogExport.columns.count }, "every row has every column")
        let row = Dictionary(uniqueKeysWithValues: zip(DiveLogExport.columns, rows[1]))
        XCTAssertEqual(row["dive_site"], "Salt Pier, Bonaire")
        XCTAssertEqual(row["dive_region"], "Tropical Atlantic Regions")
        XCTAssertEqual(row["dive_date"], "2026-03-14")
        XCTAssertEqual(row["dive_start_time"], "09:30")
        XCTAssertEqual([row["dive_max_depth"], row["dive_max_depth_unit"]], ["21", "metres"])
        XCTAssertEqual([row["dive_visibility"], row["dive_visibility_unit"]], ["60", "feet"])
        XCTAssertEqual(row["sighting_notes"], "Two of them, \"huge\"\nnear the wall", "round-trips through a CSV reader")
        XCTAssertEqual([row["sighting_depth"], row["sighting_depth_unit"]], ["12.5", "metres"])
        XCTAssertEqual(row["common_name"], "Queen Angelfish")
        XCTAssertEqual(row["saved_from"], "search")
        let unassignedRow = Dictionary(uniqueKeysWithValues: zip(DiveLogExport.columns, rows[2]))
        XCTAssertEqual(unassignedRow["dive_id"], "")
        XCTAssertEqual(unassignedRow["common_name"], "Spotted Eagle Ray")
    }

    func testOneDiveExportAndJSONRoundTrip() throws {
        let item = sighting("Queen Angelfish", notes: "Pair")
        let dive = Dive(date: try XCTUnwrap(LocalDate("2026-03-14")), siteName: "Salt Pier", createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000.25))
        let export = DiveLogExport.oneDive(DiveWithSightings(dive: dive, sightings: [item]), now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(export.rowCount, 1)
        XCTAssertTrue(export.unassigned.isEmpty, "a one-dive export has only that dive")
        let document = try DiveLogExport.jsonDecoder.decode(DiveLogExport.Document.self, from: export.json())
        XCTAssertEqual(document, export.document)
        XCTAssertEqual(document.format, "diveid-dive-log")
        XCTAssertEqual(document.dives.first?.sightings.first?.notes, "Pair")
        XCTAssertEqual(document.dives.first?.dive.createdAt, dive.createdAt, "fractions of a second survive")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = try export.write(.csv, name: "Salt Pier, Bonaire!", directory: directory)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("DiveID-Salt-Pier-Bonaire-"))
        XCTAssertEqual(url.pathExtension, "csv")
    }

    /// A small RFC 4180 reader, to check the escaping round-trips.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var chars = Array(text)[...]
        while let c = chars.popFirst() {
            if quoted {
                if c == "\"" { if chars.first == "\"" { field.append("\""); chars.removeFirst() } else { quoted = false } } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\r\n" || c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        return rows
    }
}

private actor FlakyLogRepository: SavedIdentificationRepository, DiveLogRepository {
    let base: InMemorySavedIdentificationRepository
    var failing = false
    init(base: InMemorySavedIdentificationRepository) { self.base = base }
    func setFailing(_ value: Bool) { failing = value }
    private func check() throws { if failing { throw CocoaError(.fileWriteOutOfSpace) } }
    func fetchAll() async throws -> [SavedIdentification] { try await base.fetchAll() }
    func save(_ value: SavedIdentification) async throws -> SavedIdentification { try check(); return await base.save(value) }
    func remove(id: UUID) async throws { try check(); await base.remove(id: id) }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) async throws -> SavedIdentification? { await base.savedIdentification(sourceSessionID: sourceSessionID, speciesID: speciesID) }
    func dives() async throws -> [DiveWithSightings] { await base.dives() }
    func createDive(_ dive: Dive) async throws -> Dive { try check(); return try await base.createDive(dive) }
    func updateDive(_ dive: Dive) async throws -> Dive { try check(); return try await base.updateDive(dive) }
    func deleteDive(id: UUID, sightings: DiveDeletion) async throws { try check(); try await base.deleteDive(id: id, sightings: sightings) }
    func assign(sightingIDs: [UUID], toDive diveID: UUID) async throws { try check(); try await base.assign(sightingIDs: sightingIDs, toDive: diveID) }
    func unassign(sightingIDs: [UUID]) async throws { try check(); try await base.unassign(sightingIDs: sightingIDs) }
    func updateSighting(id: UUID, depth: Depth?, notes: String?) async throws { try check(); try await base.updateSighting(id: id, depth: depth, notes: notes) }
}

private actor SightingsOnlyRepository: SavedIdentificationRepository {
    var values: [SavedIdentification] = []
    func fetchAll() -> [SavedIdentification] { values }
    func save(_ value: SavedIdentification) -> SavedIdentification { values.append(value); return value }
    func remove(id: UUID) { values.removeAll { $0.id == id } }
    func savedIdentification(sourceSessionID: UUID, speciesID: UUID) -> SavedIdentification? { nil }
}
