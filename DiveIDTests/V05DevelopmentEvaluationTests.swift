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
    let split: String?
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

extension V05DevelopmentEvaluationTests {
    /// Opt-in diagnostics: the failure list comes from a fresh evaluation report,
    /// never a hardcoded species list. Singleton ranking exposes scores outside
    /// the normal ten-result presentation boundary without increasing app limits.
    @MainActor
    func testTraceRetrievedRankFailures() async throws {
        guard let baselinePath = ProcessInfo.processInfo.environment["DIVEID_RANK_TRACE_BASELINE"],
              let outputPath = ProcessInfo.processInfo.environment["DIVEID_RANK_TRACE_REPORT"] else {
            throw XCTSkip("Set DIVEID_RANK_TRACE_BASELINE and DIVEID_RANK_TRACE_REPORT for detailed ranking evidence")
        }
        let baseline = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: baselinePath))) as? [String: Any])
        let groups = try XCTUnwrap(baseline["groups"] as? [[String: Any]])
        let failedIDs = Set(groups.flatMap { $0["cases"] as? [[String: Any]] ?? [] }.filter {
            ($0["failures"] as? [String] ?? []).contains("rankRequirement")
        }.compactMap { $0["id"] as? String })
        let fixture = try JSONDecoder().decode(V05Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "V05Development.v2")))
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        var rows: [[String: Any]] = []
        for item in fixture.cases where failedIDs.contains(item.id) {
            let pack = try await repository.loadPack(id: item.selectedPackID)
            let observation = await LocalObservationParser().parse(item.description)
            let documents = pack.profiles.map { SpeciesSearchDocumentBuilder().document(from: $0, pack: pack.metadata) }
            let retrieved = try await BM25SpeciesCandidateRetriever().retrieve(query: item.description, documents: documents, limit: pack.profiles.count)
            let accepted = Set(item.expectedSpeciesIDs + item.acceptableSpeciesIDs)
            for structured in [false, true] {
                let pool = structured ? pack.profiles.map(\.id) : Array(retrieved.prefix(50).map(\.speciesID))
                var all: [RankedLocalSpecies] = []
                var singletons: [UUID: RankedLocalSpecies] = [:]
                for profile in pack.profiles where pool.contains(profile.id) || accepted.contains(profile.id) {
                    let retrievalIndex = retrieved.firstIndex { $0.speciesID == profile.id }
                    let signal: SpeciesRetrievalSignal? = structured ? nil : retrievalIndex.map { index in
                        let r = retrieved[index]
                        return .init(source: r.evidence, scoreKind: r.scoreKind, score: r.retrievalScore, rank: index + 1, evidence: r.matchedTerms)
                    }
                    let ranked = try await LocalSpeciesRanker().rank(input: .init(description: item.description, observation: observation,
                        candidates: [.init(speciesID: profile.id, profile: profile, retrieval: signal)]))
                    if let value = ranked.first {
                        singletons[profile.id] = value
                        if pool.contains(profile.id) { all.append(value) }
                    }
                }
                all.sort {
                    if $0.orderingScore != $1.orderingScore { return $0.orderingScore > $1.orderingScore }
                    if $0.profile.commonName != $1.profile.commonName { return $0.profile.commonName < $1.profile.commonName }
                    return $0.profile.id.uuidString < $1.profile.id.uuidString
                }
                let engine: any DescriptionSearching = structured ? StructuredDescriptionSearchEngine() : HybridDescriptionSearchEngine()
                let result = try await engine.search(description: item.description, pack: pack)
                let displayed = try await LocalMarineLifeIdentificationService(catalogRepository: repository, searchEngine: engine).identify(
                    request: .init(source: .description(item.description), context: .init(region: item.selectedPackID)), processedPhoto: nil)
                XCTAssertEqual(result.candidates.map(\.profile.id), Array(all.prefix(10).map(\.profile.id)), item.id)
                XCTAssertEqual(displayed.map(\.species.id), result.candidates.map(\.profile.id), item.id)
                let store = InMemoryIdentificationSessionStore()
                let sessionID = try await store.createSession(for: .init(source: .description(item.description), context: .init(region: item.selectedPackID)))
                let model = IdentificationResultsViewModel(sessionID: sessionID,
                    service: V05TraceReplayService(matches: displayed), sessionStore: store, catalog: repository)
                await model.loadIfNeeded()
                let presented: [IdentificationMatch]
                switch model.state {
                case .loaded(let values): presented = values
                case .empty: presented = []
                default: XCTFail("Result normalization did not complete: \(item.id)"); presented = []
                }
                XCTAssertEqual(presented.map(\.species.id), displayed.map(\.species.id), item.id)
                XCTAssertEqual(presented.map(\.rank), displayed.map(\.rank), item.id)
                XCTAssertEqual(presented.map(\.score), displayed.map(\.score), item.id)
                func evidence(_ id: UUID) -> [String: Any] {
                    let r = retrieved.firstIndex { $0.speciesID == id }
                    let v = singletons[id]
                    return ["id": id.uuidString, "name": pack.profiles.first { $0.id == id }!.commonName,
                        "lexicalRetrievalRank": r.map { $0 + 1 } as Any? ?? NSNull(),
                        "lexicalRetrievalScore": r.map { retrieved[$0].retrievalScore } as Any? ?? NSNull(),
                        "retrievalTerms": r.map { retrieved[$0].matchedTerms } ?? [],
                        "candidateLimit": structured ? pack.profiles.count : 50,
                        "survivedCandidateSelection": pool.contains(id), "biologicallyEligible": v != nil,
                        "eligibilityEvaluation": pool.contains(id) ? "selected-candidate" : "diagnostic-only-outside-pool",
                        "support": v?.matchedClues ?? [], "contradictions": v?.conflictingClues ?? [],
                        "rawBiologicalScore": v?.rawScore as Any? ?? NSNull(),
                        "normalizedRetrievalRelevance": v?.retrievalRelevance as Any? ?? NSNull(),
                        "orderingScore": v?.orderingScore as Any? ?? NSNull(),
                        "relativeMatchScore": v?.score as Any? ?? NSNull(),
                        "informationLevel": v?.informationLevel.rawValue as Any? ?? NSNull(),
                        "rankBeforePresentationLimit": all.firstIndex { $0.profile.id == id }.map { $0 + 1 } as Any? ?? NSNull(),
                        "displayedRank": displayed.firstIndex { $0.species.id == id }.map { $0 + 1 } as Any? ?? NSNull()]
                }
                rows.append(["id": item.id, "description": item.description, "engine": structured ? "structured-full-pack" : "production-bm25-50-biological",
                    "normalizedText": observation.normalizedText, "tokens": observation.tokens.sorted(),
                    "categories": observation.categories.sorted(), "colors": observation.colors.sorted(), "markings": observation.markings.sorted(),
                    "bodyShapes": observation.bodyShapes.sorted(), "habitats": observation.habitats.sorted(), "behaviors": observation.behaviors.sorted(),
                    "sizeCentimeters": observation.approximateSizeCentimeters as Any? ?? NSNull(), "depthMeters": observation.approximateDepthMeters as Any? ?? NSNull(),
                    "targets": accepted.sorted { $0.uuidString < $1.uuidString }.map(evidence),
                    "leaders": all.prefix(10).map { evidence($0.profile.id) }, "servicePreservedOrdering": true, "resultModelPreservedOrderingAndScores": true])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["cases": rows], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data([10])).write(to: URL(fileURLWithPath: outputPath))
    }
}

private struct V05TraceReplayService: MarineLifeIdentificationService {
    let matches: [IdentificationMatch]
    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] { matches }
}


extension V05DevelopmentEvaluationTests {
    /// External custodian data only. No per-case assertions or console diagnostics
    /// reveal holdout text/identities. The driver retains raw results privately.
    func testIndependentCustodianBaseline() async throws {
        guard let input = ProcessInfo.processInfo.environment["DIVEID_INDEPENDENT_INPUT"],
              let output = ProcessInfo.processInfo.environment["DIVEID_INDEPENDENT_OUTPUT"] else {
            throw XCTSkip("Independent observations have not been supplied")
        }
        XCTAssertEqual(DescriptionRetrievalEngine.productionDefault, .productionBM25)
        let fixture = try JSONDecoder().decode(V05Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var rows: [[String: Any]] = []
        for publication in [false, true] {
            let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle,
                resourceResolutionMode: .bundleOnly, access: publication ? .publication : .experimentalDevelopment)
            var packs: [OfflineIdentificationPackID: OfflineIdentificationPack] = [:]
            for metadata in try await repository.availablePacks() {
                packs[metadata.id] = try await repository.loadPack(id: metadata.id)
            }
            let sizes = Dictionary(uniqueKeysWithValues: [OfflineIdentificationPackID.caribbean, .tropicalPacific].map {
                ($0.rawValue, packs[$0]?.profiles.count ?? 0)
            })
            let capture = V05Capture()
            let service = LocalMarineLifeIdentificationService(catalogRepository: repository,
                searchEngine: V05Engine(base: ConfiguredDescriptionSearchEngine(selection: .productionDefault,
                    bundle: TestResources.productionBundle), capture: capture))
            for item in fixture.cases {
                let accepted = Set(item.expectedSpeciesIDs + item.acceptableSpeciesIDs)
                let known = Set(packs[item.selectedPackID]?.profiles.map(\.id) ?? [])
                let blocked = packs[item.selectedPackID] == nil || (!accepted.isEmpty && accepted.isDisjoint(with: known))
                var matches: [IdentificationMatch] = []
                var errorKind: String? = nil
                if !blocked && item.kind != "unresolved" {
                    do {
                        matches = try await service.identify(request: .init(source: .description(item.description),
                            context: .init(region: item.selectedPackID)), processedPhoto: nil)
                    } catch let error as LocalIdentificationError {
                        if case .regionMismatch = error { errorKind = "regionConflict" }
                        else { errorKind = "serviceError" }
                    } catch { errorKind = "serviceError" }
                }
                let captured = await capture.take()
                let rank = matches.firstIndex { accepted.contains($0.species.id) }.map { $0 + 1 }
                let confidenceOK = matches.allSatisfy { $0.score.isFinite && (0...item.maximumConfidence).contains($0.score)
                    && $0.scoreKind == .relativeMatch && ($0.informationLevel != .limited || $0.score <= 0.64) }
                let correct: Bool
                switch item.kind {
                case "identification": correct = errorKind == nil && (rank.map { $0 <= 3 } ?? false)
                case "ambiguous": correct = errorKind == nil && confidenceOK && (matches.isEmpty || (rank.map { $0 <= 10 } ?? false))
                case "noMatch": correct = errorKind == nil && matches.isEmpty
                case "regionConflict": correct = errorKind == "regionConflict"
                default: correct = false
                }
                rows.append(["id":item.id, "split":item.split ?? "development", "kind":item.kind,
                    "access":publication ? "publication" : "experimentalDevelopment", "blocked":blocked,
                    "packSizes":sizes, "engineInvoked":captured.started,
                    "actualEngine":captured.started ? "production-bm25-50-biological" : "not-executed",
                    "recalled":!accepted.isDisjoint(with: captured.result?.retrievedSpeciesIDs ?? []),
                    "rank":rank as Any? ?? NSNull(), "outcomeCorrect":!blocked && correct, "confidenceOK":confidenceOK,
                    "serviceError":errorKind as Any? ?? NSNull(), "returnedCount":matches.count,
                    "relativeStrengths":matches.map(\.score),
                    "candidateRanks":Dictionary(uniqueKeysWithValues: accepted.compactMap { id in
                        captured.result?.retrievedSpeciesIDs.firstIndex(of: id).map { (id.uuidString, $0 + 1) }
                    })])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["rows":rows], options: [.sortedKeys])
        let url = URL(fileURLWithPath: output)
        try data.write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output)
    }
}
