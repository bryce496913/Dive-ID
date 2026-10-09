import Foundation
import XCTest
@testable import DiveID

private struct V05Case: Decodable {
    let id: String
    let description: String
    let selectedPackID: OfflineIdentificationPackID
    let kind: String
    let expectedSpeciesIDs: [UUID]
    let acceptableSpeciesIDs: [UUID]
    let maximumAcceptableRank: Int?
    let maximumConfidence: Double
    let provenance: String
    let evidenceIDs: [String]
}

private struct V05Fixture: Decodable {
    struct Evidence: Decodable { let id: String; let speciesID: UUID; let references: [String] }
    let schemaVersion: Int
    let suiteID: String
    let cases: [V05Case]
    let evidence: [Evidence]
}

private struct V05Protocol: Decodable {
    let suiteID: String
    let fixtureSHA256: String
    let minimumRates: [String: Double]
}

private actor V05Capture {
    private var result: DescriptionSearchResult?
    private var started = false
    func begin() { started = true }
    func save(_ value: DescriptionSearchResult) { result = value }
    func take() -> (started: Bool, result: DescriptionSearchResult?) {
        defer { result = nil; started = false }
        return (started, result)
    }
}

private struct V05Engine: DescriptionSearching {
    let base: any DescriptionSearching
    let capture: V05Capture
    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        await capture.begin()
        let value = try await base.search(description: description, pack: pack)
        await capture.save(value)
        return value
    }
}

private struct V05Counts {
    var eligible = 0, blocked = 0, positive = 0, recalled = 0, top1 = 0, top3 = 0, top10 = 0
    var noMatch = 0, noMatchCorrect = 0, conflict = 0, conflictCorrect = 0
    var ambiguous = 0, ambiguousAccepted = 0, confidenceChecked = 0, confidenceCompliant = 0
    var engineInvocations = 0
    var json: [String: Any] {
        ["eligibleCases": eligible, "coverageBlockedCases": blocked, "positiveDenominator": positive,
         "candidateRecallHits": recalled, "top1": top1, "top3": top3, "top10": top10,
         "noMatchDenominator": noMatch, "correctNoMatch": noMatchCorrect, "falsePositives": noMatch - noMatchCorrect,
         "regionConflictDenominator": conflict, "correctRegionConflicts": conflictCorrect,
         "ambiguousDenominator": ambiguous, "ambiguousAccepted": ambiguousAccepted,
         "confidenceDenominator": confidenceChecked, "confidenceCompliant": confidenceCompliant,
         "actualEngineInvocations": engineInvocations]
    }
    var rates: [String: (Int, Int)] {
        ["candidateRecall": (recalled, positive), "top1": (top1, positive), "top3": (top3, positive),
         "top10": (top10, positive), "noMatchCorrect": (noMatchCorrect, noMatch),
         "regionConflictCorrect": (conflictCorrect, conflict), "confidenceCompliant": (confidenceCompliant, confidenceChecked)]
    }
}

final class V05DevelopmentEvaluationTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    func testVersionedDevelopmentEvaluationThroughApplicationService() async throws {
        let version = ProcessInfo.processInfo.environment["DIVEID_V05_VERSION"] ?? "2"
        guard ["1", "2"].contains(version) else { return XCTFail("Unsupported frozen evaluation version") }
        let fixtureData = try Data(contentsOf: TestResources.fixture(named: "V05Development.v\(version)"))
        let fixture = try JSONDecoder().decode(V05Fixture.self, from: fixtureData)
        let contract = try JSONDecoder().decode(V05Protocol.self, from: Data(contentsOf: root.appendingPathComponent("Data/Evaluation/V05Protocol.v\(version).json")))
        XCTAssertEqual(SHA256Digest.hex(fixtureData), contract.fixtureSHA256, "Frozen fixture changed")
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(fixture.suiteID, contract.suiteID)
        XCTAssertEqual(fixture.cases.count, 46)
        XCTAssertEqual(Set(fixture.cases.map(\.id)).count, fixture.cases.count)
        XCTAssertEqual(DescriptionRetrievalEngine.productionDefault, .productionBM25)
        let evidenceIDs = Set(fixture.evidence.map(\.id))
        for item in fixture.cases {
            XCTAssertTrue(item.provenance.hasPrefix("synthetic-"))
            XCTAssertTrue(Set(item.evidenceIDs).isSubset(of: evidenceIDs))
            XCTAssertTrue(["identification", "ambiguous", "noMatch", "regionConflict"].contains(item.kind))
            if item.kind == "identification" {
                XCTAssertFalse(item.expectedSpeciesIDs.isEmpty)
                XCTAssertFalse(item.evidenceIDs.isEmpty)
                XCTAssertNotNil(item.maximumAcceptableRank)
            }
        }
        var groups: [[String: Any]] = []
        for publication in [false, true] {
            let repository = BundleMarineSpeciesCatalogRepository(
                bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly,
                access: publication ? .publication : .experimentalDevelopment)
            let available = try await repository.availablePacks()
            var packs: [OfflineIdentificationPackID: OfflineIdentificationPack] = [:]
            for metadata in available { packs[metadata.id] = try await repository.loadPack(id: metadata.id) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let fingerprints = try Dictionary(uniqueKeysWithValues: packs.map { (id, pack) in
                (id.rawValue, SHA256Digest.hex(try encoder.encode(pack.profiles)))
            })
            let sizes = Dictionary(uniqueKeysWithValues: [OfflineIdentificationPackID.caribbean, .tropicalPacific].map { ($0.rawValue, packs[$0]?.profiles.count ?? 0) })
            for structured in [false, true] {
                let engineName = structured ? "structured-full-pack" : "production-bm25-50-biological"
                let access = publication ? "publication" : "experimentalDevelopment"
                let capture = V05Capture()
                let base: any DescriptionSearching = structured ? StructuredDescriptionSearchEngine()
                    : ConfiguredDescriptionSearchEngine(selection: .productionDefault, bundle: TestResources.productionBundle)
                let service = LocalMarineLifeIdentificationService(catalogRepository: repository,
                    searchEngine: V05Engine(base: base, capture: capture))
                var counts = V05Counts(), byRegion: [String: V05Counts] = [:]
                var rows: [[String: Any]] = []
                for item in fixture.cases {
                    let knownIDs = Set(packs[item.selectedPackID]?.profiles.map(\.id) ?? [])
                    let accepted = Set(item.expectedSpeciesIDs + item.acceptableSpeciesIDs)
                    let targetUnavailable = !accepted.isEmpty && accepted.isDisjoint(with: knownIDs)
                    let packUnavailable = packs[item.selectedPackID] == nil
                    let coverageBlocked = targetUnavailable || packUnavailable
                    if !publication { XCTAssertFalse(coverageBlocked, "Development fixture has missing identity: \(item.id)") }
                    var matches: [IdentificationMatch] = []
                    var outcomeError: String? = nil
                    do {
                        matches = try await service.identify(request: .init(source: .description(item.description),
                            context: .init(region: item.selectedPackID)), processedPhoto: nil)
                    } catch let error as LocalIdentificationError {
                        switch error {
                        case .regionMismatch: outcomeError = "regionConflict"
                        case .catalogueLoadFailed(let failure): outcomeError = failure.code.rawValue
                        default: outcomeError = String(describing: error)
                        }
                    } catch { outcomeError = String(describing: error) }
                    let invocation = await capture.take()
                    let captured = invocation.result
                    let retrieved = captured?.retrievedSpeciesIDs ?? []
                    let rank = matches.firstIndex { accepted.contains($0.species.id) }.map { $0 + 1 }
                    let recalled = !accepted.isDisjoint(with: retrieved)
                    let confidenceOK = matches.allSatisfy { $0.score.isFinite && (0...item.maximumConfidence).contains($0.score) && $0.scoreKind == .relativeMatch && ($0.informationLevel != .limited || $0.score <= 0.64) }
                    let rankOK = item.maximumAcceptableRank.map { limit in rank.map { $0 <= limit } ?? false } ?? true
                    let noMatchOK = outcomeError == nil && matches.isEmpty
                    let conflictOK = outcomeError == "regionConflict"
                    var failures: [String] = []
                    if !coverageBlocked {
                        if item.kind == "identification" || item.kind == "ambiguous" {
                            if !rankOK { failures.append("rankRequirement") }
                            if outcomeError != nil { failures.append("unexpectedServiceError") }
                        } else if item.kind == "noMatch" && !noMatchOK { failures.append("noMatch") }
                        else if item.kind == "regionConflict" && !conflictOK { failures.append("regionConflict") }
                        if !confidenceOK { failures.append("confidenceLimit") }
                    } else if packUnavailable {
                        XCTAssertEqual(outcomeError, CatalogueDiagnosticCode.publicationUnavailable.rawValue, item.id)
                        XCTAssertFalse(invocation.started, "Unavailable pack must not execute an engine")
                    }
                    func accumulate(_ c: inout V05Counts) {
                        if invocation.started { c.engineInvocations += 1 }
                        if coverageBlocked { c.blocked += 1; return }
                        c.eligible += 1
                        c.confidenceChecked += 1
                        if confidenceOK { c.confidenceCompliant += 1 }
                        if item.kind == "identification" {
                            c.positive += 1
                            if recalled { c.recalled += 1 }
                            if let rank { if rank <= 1 { c.top1 += 1 }; if rank <= 3 { c.top3 += 1 }; if rank <= 10 { c.top10 += 1 } }
                        } else if item.kind == "ambiguous" { c.ambiguous += 1; if rankOK && outcomeError == nil { c.ambiguousAccepted += 1 } }
                        else if item.kind == "noMatch" { c.noMatch += 1; if noMatchOK { c.noMatchCorrect += 1 } }
                        else if item.kind == "regionConflict" { c.conflict += 1; if conflictOK { c.conflictCorrect += 1 } }
                    }
                    accumulate(&counts)
                    var regional = byRegion[item.selectedPackID.rawValue] ?? V05Counts()
                    accumulate(&regional); byRegion[item.selectedPackID.rawValue] = regional
                    rows.append(["id": item.id, "pack": item.selectedPackID.rawValue, "kind": item.kind,
                        "coverageBlocked": coverageBlocked, "candidateRecalled": recalled,
                        "retrievedCandidateCount": retrieved.count,
                        "retrievedTargetRanks": Dictionary(uniqueKeysWithValues: accepted.compactMap { id in
                            retrieved.firstIndex(of: id).map { (id.uuidString, $0 + 1) }
                        }),
                        "observedRegions": captured?.queryAnalysis.observedRegions.sorted() ?? [],
                        "packRegionCompatibility": captured.map { String(describing: $0.queryAnalysis.packRegionCompatibility) } ?? "not-evaluated",
                        "displayedIDs": matches.map { $0.species.id.uuidString },
                        "displayedRank": rank as Any? ?? NSNull(), "confidence": matches.map(\.score),
                        "informationLevels": matches.map { $0.informationLevel?.rawValue ?? "unknown" },
                        "actualEngine": invocation.started ? engineName : "not-executed",
                        "diagnostic": captured?.diagnostics.disposition.rawValue ?? (invocation.started ? "engine-failed" : "engine-not-executed"),
                        "retrievalLimit": captured?.retrievalLimit as Any? ?? NSNull(),
                        "serviceError": outcomeError as Any? ?? NSNull(), "failures": failures])
                    XCTAssertTrue(failures.isEmpty, "\(access) \(engineName) \(item.id): \(failures)")
                }
                var gates: [[String: Any]] = []
                for key in contract.minimumRates.keys.sorted() {
                    let (hits, total) = counts.rates[key]!
                    let floor = contract.minimumRates[key]!
                    let passed = total > 0 && Double(hits) / Double(total) >= floor
                    gates.append(["metric": key, "hits": hits, "denominator": total, "minimumRate": floor,
                                  "status": total == 0 ? "not-evaluated" : (passed ? "passed" : "failed")])
                    if total > 0 { XCTAssertTrue(passed, "\(access) \(engineName) \(key)=\(hits)/\(total), requires \(floor)") }
                }
                groups.append(["access": access, "requestedEngine": engineName, "packSizes": sizes,
                    "loadedProfileFingerprints": fingerprints, "counts": counts.json, "byRegion": byRegion.mapValues(\.json), "gates": gates, "cases": rows])
            }
        }
        let report: [String: Any] = ["schemaVersion": 1, "suiteID": fixture.suiteID,
            "fixtureSHA256": contract.fixtureSHA256, "freezeCommit": version == "1" ? "1481b619598c40b63cebbb89985e92064507567e" : "5a9dbf3d455d16274ac3b73a77b165e1db7ca9c0",
            "confidenceMeaning": "relative match score; not calibrated probability", "groups": groups]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        if let path = ProcessInfo.processInfo.environment["DIVEID_V05_REPORT"] {
            try (data + Data([10])).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        for group in groups { print("V05_EVALUATION \(group["access"]!) \(group["requestedEngine"]!) \(group["counts"]!)") }
    }
}
