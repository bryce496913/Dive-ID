import Foundation
import XCTest
@testable import DiveID

/// Runs the frozen V05 v2 cases against the Global pack instead of each case's regional
/// pack. The fixture is not modified: expected species are mapped through the merge plan
/// (a retired UUID counts as its kept taxon). Gates use the frozen V05 protocol floors.
/// Runs only when DIVEID_GLOBAL_EVAL_REPORT names the report file.
final class GlobalPackEvaluationTests: XCTestCase {
    private struct Case: Decodable {
        let id: String
        let description: String
        let selectedPackID: OfflineIdentificationPackID
        let kind: String
        let expectedSpeciesIDs: [UUID]
        let acceptableSpeciesIDs: [UUID]
        let maximumAcceptableRank: Int?
        let maximumConfidence: Double
    }
    private struct Fixture: Decodable { let cases: [Case] }
    private struct EvaluationProtocol: Decodable { let minimumRates: [String: Double] }

    /// Serves one composed pack, so the evaluation goes through the application service.
    private struct InMemoryCatalog: MarineSpeciesCatalogRepository {
        let pack: OfflineIdentificationPack
        func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
        func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
            guard id == pack.metadata.id else { throw LocalCatalogError.unsupportedPack }
            return pack
        }
    }

    /// Keeps the retrieved pool of the latest search, so candidate recall can be measured
    /// through the application service.
    private actor RetrievalLog {
        var last: [UUID] = []
        func record(_ ids: [UUID]) { last = ids }
    }

    private struct RecordingEngine: DescriptionSearching {
        let inner: any DescriptionSearching
        let log: RetrievalLog
        func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
            let result = try await inner.search(description: description, pack: pack)
            await log.record(result.retrievedSpeciesIDs)
            return result
        }
    }

    /// Gates are asserted on the pack as written. The other variants are diagnostics.
    private static let assertedVariant = "global-as-written"
    /// A single global pack has no region aliases, so a described location can never
    /// conflict with it (Docs/HybridRankingContract.md: location never filters). The
    /// regional pack-mismatch gate has no applicable case; it is reported, not asserted.
    private static let notApplicableGates: [String: String] = [
        "regionConflictCorrect": "a single global pack has no pack-region mismatch; location never filters"
    ]

    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private func repository() -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
    }

    /// Retired UUID -> kept UUID, from the merge plan.
    private func keptIdentity() throws -> [UUID: UUID] {
        let text = try String(contentsOf: root.appendingPathComponent("Data/GlobalMarine/FishBase/MergePlan.csv"), encoding: .utf8)
        var lines = text.split(separator: "\n").map(String.init)
        let header = lines.removeFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let input = try XCTUnwrap(header.firstIndex(of: "inputUUID")), planned = try XCTUnwrap(header.firstIndex(of: "plannedUUID")),
            role = try XCTUnwrap(header.firstIndex(of: "role"))
        var map: [UUID: UUID] = [:]
        for line in lines {
            // Names may contain commas but are quoted; UUID columns never are, so split on the unquoted structure.
            let fields = Self.csvFields(line)
            guard fields.count == header.count, fields[role] == "retire",
                  let from = UUID(uuidString: fields[input]), let to = UUID(uuidString: fields[planned]) else { continue }
            map[from] = to
        }
        return map
    }

    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = [], current = "", quoted = false
        for character in line {
            if character == "\"" { quoted.toggle() } else if character == "," && !quoted { fields.append(current); current = "" } else { current.append(character) }
        }
        fields.append(current)
        return fields
    }

    func testFrozenV05CasesAgainstTheGlobalPack() async throws {
        // About 6 s per query at full size (see Docs/GlobalPackEvaluation.md), so opt-in.
        guard ProcessInfo.processInfo.environment["DIVEID_GLOBAL_EVAL_REPORT"] != nil else {
            throw XCTSkip("Set DIVEID_GLOBAL_EVAL_REPORT to run the V05 cases against the Global pack.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "V05Development.v2")))
        let floors = try JSONDecoder().decode(EvaluationProtocol.self, from: Data(contentsOf: root.appendingPathComponent("Data/Evaluation/V05Protocol.v2.json"))).minimumRates
        let kept = try keptIdentity()
        let global = try await repository().loadPack(id: .global)
        let caribbean = try await repository().loadPack(id: .caribbean)
        let pacificIDs = Set(try await repository().loadPack(id: .tropicalPacific).profiles.map(\.id))
        let subsetProfiles = global.profiles.filter { pacificIDs.contains($0.id) }
        var subsetMetadata = global.metadata
        subsetMetadata.speciesCount = subsetProfiles.count
        // Global carries the 8 Caribbean species as the regional pack's own records (drafts in
        // Global), so this variant now equals the pack as written apart from review status.
        // It swaps the regional records in rather than appending them, so no ID appears twice.
        let caribbeanIDs = Set(caribbean.profiles.map(\.id))
        let composedProfiles = global.profiles.filter { !caribbeanIDs.contains($0.id) } + caribbean.profiles
        var composed = global.metadata
        composed.speciesCount = composedProfiles.count
        // The subset Release actually exposes: publication access. Unavailable means Global is
        // gated out of Release (GlobalRegion.definition) or has no approved record, so the subset is empty.
        let release: OfflineIdentificationPack
        do {
            release = try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication).loadPack(id: .global)
        } catch let failure as CatalogueLoadFailure where failure.code == .publicationUnavailable {
            var empty = global.metadata
            empty.speciesCount = 0
            release = OfflineIdentificationPack(metadata: empty, profiles: [])
        }
        // What-if only, never approval: batch 1's 250 records, which await re-review.
        let batchManifest = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Data/CatalogReview/GlobalBatches/batch-01"), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("manifest-g1-") })
        let batchIDs = Set(try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: batchManifest)) as? [String: Any])?["records"] as? [[String: Any]])
            .compactMap { ($0["speciesID"] as? String).flatMap(UUID.init(uuidString:)) })
        var pendingMetadata = global.metadata
        let pendingProfiles = global.profiles.filter { batchIDs.contains($0.id) }
        pendingMetadata.speciesCount = pendingProfiles.count
        let variants: [(String, OfflineIdentificationPack)] = [
            ("global-as-written", global),
            ("global-plus-caribbean-8 (in memory only)", OfflineIdentificationPack(metadata: composed, profiles: composedProfiles)),
            // Diagnostic: Global's rebuilt text at regional size, separating text effects from scale effects.
            ("global-records-for-tropical-pacific-ids (diagnostic)", OfflineIdentificationPack(metadata: subsetMetadata, profiles: subsetProfiles)),
            ("global-release-approved", release),
            ("global-batch-01-pending (what-if; not approved)", OfflineIdentificationPack(metadata: pendingMetadata, profiles: pendingProfiles))
        ]
        var groups: [[String: Any]] = []
        for (name, pack) in variants {
            let log = RetrievalLog()
            let service = LocalMarineLifeIdentificationService(catalogRepository: InMemoryCatalog(pack: pack),
                searchEngine: RecordingEngine(inner: ConfiguredDescriptionSearchEngine(selection: .productionDefault, bundle: TestResources.productionBundle), log: log))
            let known = Set(pack.profiles.map(\.id))
            var tally: [String: (hits: Int, total: Int)] = [:]
            func count(_ key: String, _ hit: Bool) { tally[key, default: (0, 0)].total += 1; if hit { tally[key, default: (0, 0)].hits += 1 } }
            var rows: [[String: Any]] = [], blocked: [String] = [], byRegion: [String: [String: Int]] = [:]
            for item in fixture.cases {
                let accepted = Set((item.expectedSpeciesIDs + item.acceptableSpeciesIDs).map { kept[$0] ?? $0 })
                // Out of scope: the target species is not in this catalogue. An empty catalogue
                // evaluates nothing, so it cannot "pass" no-match cases by returning nothing.
                if (!accepted.isEmpty && accepted.isDisjoint(with: known)) || known.isEmpty { blocked.append(item.id); continue }
                var matches: [IdentificationMatch] = [], failure: String? = nil
                await log.record([])
                do {
                    matches = try await service.identify(request: .init(source: .description(item.description), context: .init(region: .global)), processedPhoto: nil)
                } catch { failure = String(describing: error) }
                let rank = matches.firstIndex { accepted.contains($0.species.id) }.map { $0 + 1 }
                let confidenceOK = matches.allSatisfy { $0.score.isFinite && (0...item.maximumConfidence).contains($0.score) && ($0.informationLevel != .limited || $0.score <= 0.64) }
                count("confidenceCompliant", confidenceOK)
                var outcome = "evaluated"
                switch item.kind {
                case "identification":
                    count("candidateRecall", !accepted.isDisjoint(with: await log.last))
                    count("top1", rank.map { $0 <= 1 } ?? false); count("top3", rank.map { $0 <= 3 } ?? false); count("top10", rank.map { $0 <= 10 } ?? false)
                    byRegion[item.selectedPackID.rawValue, default: [:]]["positive", default: 0] += 1
                    if rank.map({ $0 <= 1 }) == true { byRegion[item.selectedPackID.rawValue, default: [:]]["top1", default: 0] += 1 }
                    if rank.map({ $0 <= 10 }) == true { byRegion[item.selectedPackID.rawValue, default: [:]]["top10", default: 0] += 1 }
                case "ambiguous":
                    count("ambiguousAccepted", item.maximumAcceptableRank.map { limit in rank.map { $0 <= limit } ?? false } ?? true)
                case "noMatch":
                    count("noMatchCorrect", failure == nil && matches.isEmpty)
                default:
                    // A regional pack-mismatch case: in one global pack a described location
                    // never blocks a search, so results are expected instead of an error.
                    outcome = failure == nil && !matches.isEmpty ? "results returned (no pack mismatch in Global)" : "no results"
                    count("regionCasesReturnResults", failure == nil && !matches.isEmpty)
                }
                rows.append(["id": item.id, "region": item.selectedPackID.rawValue, "kind": item.kind, "rank": rank as Any? ?? NSNull(),
                             "displayed": matches.prefix(3).map { $0.species.commonName }, "error": failure as Any? ?? NSNull(), "outcome": outcome,
                             "confidenceCompliant": confidenceOK, "topScore": matches.first?.score ?? 0])
            }
            let gates = floors.keys.sorted().map { key -> [String: Any] in
                let value = tally[key] ?? (0, 0)
                let status = Self.notApplicableGates[key] != nil ? "not-applicable"
                    : value.total == 0 ? "not-evaluated"
                    : Double(value.hits) / Double(value.total) >= floors[key]! ? "passed" : "failed"
                return ["metric": key, "hits": value.hits, "denominator": value.total, "minimumRate": floors[key]!, "status": status,
                        "note": Self.notApplicableGates[key] ?? ""]
            }
            groups.append(["variant": name, "packSize": pack.profiles.count, "coverageBlockedCases": blocked, "gates": gates,
                           "counts": tally.mapValues { ["hits": $0.hits, "total": $0.total] }, "byRegion": byRegion, "cases": rows])
            print("GLOBAL_EVALUATION \(name) size=\(pack.profiles.count) blocked=\(blocked.count) " + gates.map { "\($0["metric"]!)=\($0["hits"]!)/\($0["denominator"]!):\($0["status"]!)" }.joined(separator: " "))
            XCTAssertTrue(rows.allSatisfy { ($0["error"] as? String) == nil || ($0["kind"] as? String) == "noMatch" }, "\(name): the service must not fail on Global")
            guard name == Self.assertedVariant else { continue }
            for gate in gates where gate["status"] as? String != "not-applicable" {
                let metric = gate["metric"] as! String, hits = gate["hits"] as! Int, denominator = gate["denominator"] as! Int
                let floor = gate["minimumRate"] as! Double
                if denominator == 0 {
                    XCTFail("\(name): gate \(metric) was not evaluated (no applicable cases); floor \(floor)")
                } else if gate["status"] as? String != "passed" {
                    XCTFail("\(name): gate \(metric) failed: \(hits)/\(denominator) = \(String(format: "%.3f", Double(hits) / Double(denominator))) is below the floor \(floor)")
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["DIVEID_GLOBAL_EVAL_REPORT"] {
            let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "fixture": "V05Development.v2", "groups": groups], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    private struct LocationCase: Decodable {
        let id: String
        let speciesID: UUID
        let description: String
        let outOfRangeLocation: String
    }
    private struct LocationFixture: Decodable { let cases: [LocationCase] }

    /// Docs/HybridRankingContract.md: location ranks but never filters. An out-of-range
    /// clue lowers ordering by 3 only after eligibility is decided, so it never removes a
    /// candidate, and the score and confidence stay as for a species with no range.
    /// Results are capped at ten, so a demoted species can fall below the display cut;
    /// the contract does not promise display, so display is measured and reported.
    func testOutOfRangeLocationCluesStillReturnTheSpecies() async throws {
        let fixture = try JSONDecoder().decode(LocationFixture.self, from: Data(contentsOf: TestResources.fixture(named: "GlobalLocation.v1")))
        let pack = try await repository().loadPack(id: .global)
        let builder = SpeciesSearchDocumentBuilder()
        let documents = pack.profiles.map { builder.document(from: $0, pack: pack.metadata) }
        let profiles = Dictionary(uniqueKeysWithValues: pack.profiles.map { ($0.id, $0) })
        let retriever = BM25SpeciesCandidateRetriever(), parser = LocalObservationParser(), ranker = LocalSpeciesRanker()
        let engine = HybridDescriptionSearchEngine()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 6)
        var display: [String] = [], inapplicable: [String] = []
        for item in fixture.cases {
            let located = item.description + ". " + item.outOfRangeLocation
            let profile = try XCTUnwrap(profiles[item.speciesID], "\(item.id): species missing from Global")
            // Retrieved pool (the engine's top 50): adding a location must not push the species out.
            let plainPool = try await retriever.retrieve(query: item.description, documents: documents, limit: 50)
            let locatedPool = try await retriever.retrieve(query: located, documents: documents, limit: 50)
            // A species not retrieved even without a location cannot test location; that is a
            // retrieval-quality miss, which the frozen gates measure, not a location failure.
            guard plainPool.contains(where: { $0.speciesID == item.speciesID }) else {
                inapplicable.append("\(item.id): not in the retrieved pool even without a location"); continue
            }
            guard let hit = locatedPool.enumerated().first(where: { $0.element.speciesID == item.speciesID }) else {
                XCTFail("\(item.id): the location sentence pushed the species out of the retrieved pool"); continue
            }
            // Eligibility and demotion: the ranker decides each candidate on its own, before the
            // ten-result cap, so the candidate is ranked alone. The baseline is the same
            // observation with the described location removed (a neutral range).
            let candidate = SpeciesRankingCandidate(speciesID: item.speciesID, profile: profile, retrieval: SpeciesRetrievalSignal(
                source: hit.element.evidence, scoreKind: hit.element.scoreKind, score: hit.element.retrievalScore,
                rank: hit.offset + 1, evidence: hit.element.matchedTerms))
            let observation = await parser.parse(located)
            XCTAssertFalse(observation.regions.isEmpty, "\(item.id): the location was not recognised")
            let neutral = ParsedObservation(normalizedText: observation.normalizedText, tokens: observation.tokens, colors: observation.colors,
                markings: observation.markings, bodyShapes: observation.bodyShapes, habitats: observation.habitats, regions: [],
                behaviors: observation.behaviors, categories: observation.categories, approximateSizeCentimeters: observation.approximateSizeCentimeters,
                approximateDepthMeters: observation.approximateDepthMeters, colorEvidenceGroups: observation.colorEvidenceGroups,
                appearanceRelationships: observation.appearanceRelationships, domainContradiction: observation.domainContradiction)
            let baseline = try await ranker.rank(input: .init(description: located, observation: neutral, candidates: [candidate])).first
            let ranked = try await ranker.rank(input: .init(description: located, observation: observation, candidates: [candidate])).first
            guard let baseline else { inapplicable.append("\(item.id): not eligible even with a neutral range"); continue }
            guard let ranked else { XCTFail("\(item.id): the out-of-range location removed an eligible candidate"); continue }
            XCTAssertEqual(ranked.rawScore, baseline.rawScore, accuracy: 1e-9, "\(item.id): location must not change the evidence score")
            XCTAssertEqual(ranked.score, baseline.score, accuracy: 1e-9, "\(item.id): location must not change confidence")
            XCTAssertEqual(ranked.orderingScore, baseline.orderingScore - 3, accuracy: 1e-9, "\(item.id): out of range lowers ordering by exactly 3")
            // Display (the ten results shown): measured separately, not asserted.
            let shownWithout = try await engine.search(description: item.description, pack: pack).candidates.firstIndex { $0.profile.id == item.speciesID }
            let shownWith = try await engine.search(description: located, pack: pack).candidates.firstIndex { $0.profile.id == item.speciesID }
            display.append("\(item.id): pool rank \(hit.offset + 1); displayed without location \(shownWithout.map { "#\($0 + 1)" } ?? "no"), with \(shownWith.map { "#\($0 + 1)" } ?? "no")")
        }
        for line in display { print("GLOBAL_LOCATION_DISPLAY \(line)") }
        for line in inapplicable { print("GLOBAL_LOCATION_INAPPLICABLE \(line)") }
        XCTAssertGreaterThanOrEqual(display.count, 4, "too few cases can test location: \(inapplicable)")
    }

    /// Production BM25 + biological ranking on all Global records over the 116 development
    /// cases: the V05 v2 cases and the benchmark's development split (its holdout rows are
    /// dropped as soon as the fixture is decoded and never searched). Writes a per-case report
    /// when DIVEID_GLOBAL_DEV_RANKING_REPORT names a file. Quality is reported, not asserted;
    /// no-match abstention and confidence compliance are hard gates.
    func testProductionRankingOnGlobalDevelopmentCases() async throws {
        guard let path = ProcessInfo.processInfo.environment["DIVEID_GLOBAL_DEV_RANKING_REPORT"] else {
            throw XCTSkip("Set DIVEID_GLOBAL_DEV_RANKING_REPORT to evaluate production ranking on Global.")
        }
        struct DevCase { let id: String; let source: String; let description: String; let kind: String; let expected: [UUID]; let maximumConfidence: Double }
        let v05 = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "V05Development.v2")))
        let benchmark = try JSONDecoder().decode([IdentificationBenchmarkCase].self,
            from: Data(contentsOf: TestResources.fixture(named: "CaribbeanIdentificationBenchmark"))).filter { $0.split == "development" }
        let cases = v05.cases.map { DevCase(id: $0.id, source: "V05Development.v2", description: $0.description, kind: $0.kind,
                                            expected: $0.expectedSpeciesIDs, maximumConfidence: $0.maximumConfidence) }
            + benchmark.map { DevCase(id: $0.id, source: "CaribbeanIdentificationBenchmark (development)", description: $0.description,
                                      kind: $0.expectedNoUsefulMatch ? "noMatch" : "identification", expected: $0.expectedSpeciesIDs,
                                      maximumConfidence: $0.informationLevel == .limited ? 0.64 : 1) }
        let global = try await repository().loadPack(id: .global)
        let globalIDs = Set(global.profiles.map(\.id))
        let engine = HybridDescriptionSearchEngine()
        var rows: [[String: Any]] = []
        var compliant = 0
        for item in cases {
            let result = try await engine.search(description: item.description, pack: global)
            let expected = Set(item.expected)
            let rank = result.candidates.firstIndex { expected.contains($0.profile.id) }.map { $0 + 1 }
            let poolRank = result.retrievedSpeciesIDs.firstIndex { expected.contains($0) }.map { $0 + 1 }
            let scores = result.candidates.map(\.score)
            let isCompliant = result.candidates.allSatisfy {
                $0.score.isFinite && $0.score >= 0 && $0.score <= item.maximumConfidence
                    && ($0.informationLevel != .limited || $0.score <= LocalRankingWeights.limitedConfidenceCap)
            }
            if isCompliant { compliant += 1 }
            if item.kind == "noMatch" { XCTAssertTrue(result.candidates.isEmpty, "\(item.id) must abstain") }
            XCTAssertTrue(isCompliant, "\(item.id) confidence: \(scores)")
            rows.append([
                "id": item.id, "source": item.source, "kind": item.kind,
                "expectedSpeciesIDs": item.expected.map(\.uuidString),
                "expectedInGlobal": !expected.isDisjoint(with: globalIDs),
                "expectedRank": rank.map { $0 as Any } ?? NSNull(),
                "recalledInPool": poolRank != nil, "poolRank": poolRank.map { $0 as Any } ?? NSNull(),
                "poolSize": result.retrievedSpeciesIDs.count,
                "abstained": result.candidates.isEmpty,
                "top1": result.candidates.first?.profile.commonName ?? NSNull(),
                "top1Confidence": result.candidates.first?.score ?? NSNull(),
                "top3": result.candidates.prefix(3).map(\.profile.commonName),
                "expectedConfidence": rank.map { scores[$0 - 1] as Any } ?? NSNull(),
                "informationLevel": result.candidates.first?.informationLevel.rawValue ?? NSNull(),
                "confidenceCompliant": isCompliant,
            ])
        }
        func count(_ kind: String, _ test: ([String: Any]) -> Bool) -> Int { rows.filter { $0["kind"] as? String == kind && test($0) }.count }
        func within(_ k: Int) -> ([String: Any]) -> Bool { { ($0["expectedRank"] as? Int).map { $0 <= k } ?? false } }
        let identification = count("identification") { _ in true }
        let summary: [String: Any] = [
            "cases": rows.count, "identification": identification,
            "top1": count("identification", within(1)), "top3": count("identification", within(3)),
            "top10": count("identification", within(10)),
            "candidateRecall": count("identification") { $0["recalledInPool"] as? Bool == true },
            "identificationAbstained": count("identification") { $0["abstained"] as? Bool == true },
            "noMatch": count("noMatch") { _ in true }, "noMatchAbstained": count("noMatch") { $0["abstained"] as? Bool == true },
            "ambiguousAbstained": count("ambiguous") { $0["abstained"] as? Bool == true },
            "regionConflictAbstained": count("regionConflict") { $0["abstained"] as? Bool == true },
            "confidenceCompliant": compliant,
        ]
        print("GLOBAL-DEV-RANKING " + String(decoding: try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), as: UTF8.self))
        let report: [String: Any] = [
            "schemaVersion": 1, "engine": "production BM25 (50 candidates) + LocalSpeciesRanker",
            "pack": "\(global.metadata.id.rawValue):\(global.metadata.packVersion)", "speciesCount": global.profiles.count,
            "fixtures": ["V05Development.v2", "CaribbeanIdentificationBenchmark (development split only)"],
            "summary": summary, "rows": rows,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
    }
}
