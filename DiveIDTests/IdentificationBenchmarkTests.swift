import Foundation
import XCTest
@testable import DiveID

enum BenchmarkExpectedRank: String, Codable, CaseIterable {
    case top1, top3, top10, none
    var limit: Int? { switch self { case .top1: 1; case .top3: 3; case .top10: 10; case .none: nil } }
}

struct IdentificationBenchmarkCase: Codable {
    let id: String
    let split: String
    let description: String
    let selectedPackID: OfflineIdentificationPackID
    let expectedSpeciesIDs: [UUID]
    let acceptableSpeciesIDs: [UUID]
    let informationLevel: ObservationInformationLevel
    let expectedNoUsefulMatch: Bool
    let expectedRank: BenchmarkExpectedRank
    let notes: String?
}

private struct BenchmarkCounts: Codable, Equatable {
    var cases = 0, positives = 0, noMatchCases = 0
    var top1 = 0, top3 = 0, top10 = 0
    var correctNoMatch = 0, falsePositives = 0
    var candidateRecallHits = 0

    mutating func record(rank: Int?, noMatchCorrect: Bool, expectedNoMatch: Bool, candidateRecalled: Bool) {
        cases += 1
        if expectedNoMatch {
            noMatchCases += 1
            if noMatchCorrect { correctNoMatch += 1 } else { falsePositives += 1 }
        } else {
            positives += 1
            if let rank { if rank <= 1 { top1 += 1 }; if rank <= 3 { top3 += 1 }; if rank <= 10 { top10 += 1 } }
            if candidateRecalled { candidateRecallHits += 1 }
        }
    }
}

private struct BenchmarkCandidate: Codable, Equatable {
    let species: String
    let rawScore: Double
    let retrievalRelevance: Double?
    let orderingScore: Double
    let displayScore: Double
    let informationLevel: String
    let matchedEvidence: [String]
    let conflictingEvidence: [String]
}

private struct BenchmarkCaseResult: Codable, Equatable {
    let id: String
    let split: String
    let expectedRank: String
    let outcome: String
    let primaryExpectedRank: Int?
    let acceptedRank: Int?
    let candidateRecalled: Bool
    let retrievalLimit: Int
    let returnedInformationLevel: String?
    let returnedConfidence: Double?
    let candidates: [BenchmarkCandidate]
    let description: String?
}

private struct BenchmarkReport: Codable, Equatable {
    let schemaVersion: Int
    let engine: String
    let fixture: String
    let overall: BenchmarkCounts
    let splits: [String: BenchmarkCounts]
    let informationLevels: [String: BenchmarkCounts]
    let cases: [BenchmarkCaseResult]
}

private struct BenchmarkThresholds {
    static let version = 1
    // Frozen 100-case regression floors reproduce the documented 2026-09-06 run.
    static let frozenTop1 = 44, frozenTop3 = 59, frozenTop10 = 64, frozenNoMatch = 20
    // Development floors are the corresponding 70-case cohort measurements.
    static let structuredDevelopment = (top1: 38, top3: 42, top10: 45)
    static let hybridDevelopment = (top1: 43, top3: 44, top10: 45)
    static let developmentNoMatch = 14
    static let minimumCandidateRecallRate = 0.80
}

private struct FixtureCatalogRepository: MarineSpeciesCatalogRepository {
    let pack: OfflineIdentificationPack
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        guard id == pack.metadata.id else { throw LocalIdentificationError.catalogUnavailable }
        return pack
    }
}

private actor SearchCapture {
    private var value: DescriptionSearchResult?
    func store(_ result: DescriptionSearchResult) { value = result }
    func take() -> DescriptionSearchResult? { defer { value = nil }; return value }
}

private struct CapturingSearchEngine: DescriptionSearching {
    let base: any DescriptionSearching
    let capture: SearchCapture
    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        let result = try await base.search(description: description, pack: pack)
        await capture.store(result)
        return result
    }
}

private struct EmptySearchEngine: DescriptionSearching {
    func search(description: String, pack: OfflineIdentificationPack) async throws -> DescriptionSearchResult {
        DescriptionSearchResult(candidates: [], queryAnalysis: .init(observedRegions: [], packRegionCompatibility: .unspecified), retrievedSpeciesIDs: [], retrievalLimit: 1)
    }
}

private struct PerfectSimilarityRetriever: SpeciesCandidateRetrieving {
    let speciesID: UUID
    func retrieve(query: String, documents: [SpeciesSearchDocument], limit: Int) async throws -> [RetrievedSpeciesCandidate] {
        [.init(speciesID: speciesID, retrievalScore: 1, evidence: .semantic, matchedTerms: ["model similarity"])]
    }
}

final class IdentificationBenchmarkTests: XCTestCase {
    private let catalogDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DiveID/Resources/IdentificationPacks/Caribbean")

    private func fixture(named name: String = "CaribbeanIdentificationBenchmark") throws -> [IdentificationBenchmarkCase] {
        try JSONDecoder().decode([IdentificationBenchmarkCase].self, from: Data(contentsOf: TestResources.fixture(named: name)))
    }

    private func pack() throws -> OfflineIdentificationPack {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: catalogDirectory.appendingPathComponent("PackManifest.json")))
        let profiles = try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: catalogDirectory.appendingPathComponent("Creatures.json")))
        XCTAssertEqual(profiles.count, metadata.speciesCount)
        return OfflineIdentificationPack(metadata: metadata, profiles: profiles)
    }

    func testFrozenFixtureContractAndExpectedRankVocabulary() throws {
        let cases = try fixture()
        XCTAssertEqual(cases.count, 100)
        XCTAssertEqual(Set(cases.map(\.description)).count, cases.count)
        XCTAssertEqual(cases.filter { $0.split == "development" }.count, 70)
        XCTAssertEqual(cases.filter { $0.split == "holdout" }.count, 30)
        XCTAssertEqual(Set(cases.map(\.split)), ["development", "holdout"])
        XCTAssertTrue(Set(cases.map(\.informationLevel)).isSuperset(of: [.sufficient, .insufficient]))
        XCTAssertTrue(BenchmarkExpectedRank.allCases.allSatisfy { rank in
            rank == .top10 || cases.contains { $0.expectedRank == rank }
        }, "top10 is supported explicitly even though frozen v1 has no top10-only case")
        for item in cases {
            XCTAssertEqual(item.expectedRank == .none, item.expectedNoUsefulMatch, item.id)
            XCTAssertEqual(item.expectedSpeciesIDs.isEmpty, item.expectedNoUsefulMatch, item.id)
        }
        let unknown = Data("{\"id\":\"x\",\"split\":\"development\",\"description\":\"unknown rank\",\"selectedPackID\":\"caribbean\",\"expectedSpeciesIDs\":[],\"acceptableSpeciesIDs\":[],\"informationLevel\":\"insufficient\",\"expectedNoUsefulMatch\":true,\"expectedRank\":\"top5\"}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(IdentificationBenchmarkCase.self, from: unknown))
    }

    func testDevelopmentQualityGatesForStructuredAndHybrid() async throws {
        let cases = try fixture().filter { $0.split == "development" }
        XCTAssertFalse(cases.isEmpty)
        for (name, engine) in [("structured", StructuredDescriptionSearchEngine() as any DescriptionSearching), ("hybrid-bm25-50", HybridDescriptionSearchEngine(candidateLimit: 50) as any DescriptionSearching)] {
            let report = try await runBenchmark(engineName: name, engine: engine, cases: cases, fixtureName: "caribbean-v1-development", revealDescriptions: true)
            assertDevelopmentThresholds(report)
            printReport(report)
        }
    }

    func testExplicitFrozenHoldoutEvaluationMode() async throws {
        guard ProcessInfo.processInfo.environment["DIVEID_FROZEN_HOLDOUT"] == "1" else {
            throw XCTSkip("Set DIVEID_FROZEN_HOLDOUT=1 for the explicit frozen 100-case evaluation; routine development does not print holdout descriptions.")
        }
        let cases = try fixture()
        XCTAssertFalse(cases.filter { $0.split == "holdout" }.isEmpty)
        for (name, engine) in [("structured", StructuredDescriptionSearchEngine() as any DescriptionSearching), ("hybrid-bm25-50", HybridDescriptionSearchEngine(candidateLimit: 50) as any DescriptionSearching)] {
            let report = try await runBenchmark(engineName: name, engine: engine, cases: cases, fixtureName: "caribbean-v1-frozen", revealDescriptions: false)
            assertFrozenThresholds(report)
            printReport(report)
        }
    }

    func testLimitedDevelopmentFixtureConfidenceCapsAndOutcomes() async throws {
        let cases = try fixture(named: "CaribbeanLimitedDescriptions.v1")
        XCTAssertFalse(cases.isEmpty)
        XCTAssertTrue(cases.contains { $0.informationLevel == .limited && !$0.expectedNoUsefulMatch })
        XCTAssertTrue(cases.contains { $0.informationLevel == .insufficient && $0.expectedNoUsefulMatch })
        let report = try await runBenchmark(engineName: "hybrid-bm25-50", engine: HybridDescriptionSearchEngine(), cases: cases, fixtureName: "limited-v1", revealDescriptions: true)
        for (item, result) in zip(cases, report.cases) {
            if item.informationLevel == .limited {
                XCTAssertEqual(result.returnedInformationLevel, ObservationInformationLevel.limited.rawValue, item.id)
                XCTAssertLessThanOrEqual(result.returnedConfidence ?? 1, 0.64, item.id)
            }
            if item.expectedNoUsefulMatch { XCTAssertEqual(result.outcome, "correct-no-match", item.id) }
            else { XCTAssertEqual(result.outcome, "met-\(item.expectedRank.rawValue)", item.id) }
        }
    }

    func testPerfectModelSimilarityCannotUpgradeLimitedConfidence() async throws {
        let ray = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let engine = HybridDescriptionSearchEngine(retriever: PerfectSimilarityRetriever(speciesID: ray), candidateLimit: 1)
        let report = try await runBenchmark(engineName: "controlled-semantic", engine: engine, cases: [try fixture(named: "CaribbeanLimitedDescriptions.v1")[0]], fixtureName: "limited-v1", revealDescriptions: true)
        XCTAssertEqual(report.cases[0].returnedInformationLevel, ObservationInformationLevel.limited.rawValue)
        XCTAssertLessThanOrEqual(report.cases[0].returnedConfidence ?? 1, 0.64)
        XCTAssertEqual(report.cases[0].outcome, "met-top1")
    }

    func testThresholdEvaluatorRejectsDeliberatelyDegradedEngine() async throws {
        let cases = try fixture().filter { $0.split == "development" }
        let degraded = try await runBenchmark(engineName: "deliberately-empty", engine: EmptySearchEngine(), cases: cases, fixtureName: "controlled", revealDescriptions: false)
        XCTAssertThrowsError(try validateDevelopmentThresholds(degraded))
    }

    private func runBenchmark(engineName: String, engine: any DescriptionSearching, cases: [IdentificationBenchmarkCase], fixtureName: String, revealDescriptions: Bool) async throws -> BenchmarkReport {
        let catalog = try pack(), capture = SearchCapture()
        let service = LocalMarineLifeIdentificationService(catalogRepository: FixtureCatalogRepository(pack: catalog), searchEngine: CapturingSearchEngine(base: engine, capture: capture))
        var overall = BenchmarkCounts(), splits: [String: BenchmarkCounts] = [:], levels: [String: BenchmarkCounts] = [:], results: [BenchmarkCaseResult] = []
        for item in cases {
            let request = IdentificationRequest(source: .description(item.description), context: .init(region: item.selectedPackID))
            let matches: [IdentificationMatch]
            do { matches = try await service.identify(request: request, processedPhoto: nil) }
            catch LocalIdentificationError.regionMismatch { matches = [] }
            guard let evaluated = await capture.take() else { XCTFail("Engine result was not captured for \(item.id)"); continue }
            let primary = Set(item.expectedSpeciesIDs), accepted = primary.union(item.acceptableSpeciesIDs)
            let primaryRank = matches.firstIndex { primary.contains($0.species.id) }.map { $0 + 1 }
            let acceptedRank = matches.firstIndex { accepted.contains($0.species.id) }.map { $0 + 1 }
            let recalled = !item.expectedNoUsefulMatch && !accepted.isDisjoint(with: evaluated.retrievedSpeciesIDs)
            let noMatchCorrect = item.expectedNoUsefulMatch && matches.isEmpty
            let met = item.expectedRank.limit.map { limit in acceptedRank.map { $0 <= limit } ?? false } ?? noMatchCorrect
            let outcome = item.expectedNoUsefulMatch ? (noMatchCorrect ? "correct-no-match" : "false-positive") : (met ? "met-\(item.expectedRank.rawValue)" : "missed-\(item.expectedRank.rawValue)")
            let level = item.informationLevel.rawValue
            overall.record(rank: acceptedRank, noMatchCorrect: noMatchCorrect, expectedNoMatch: item.expectedNoUsefulMatch, candidateRecalled: recalled)
            splits[item.split, default: .init()].record(rank: acceptedRank, noMatchCorrect: noMatchCorrect, expectedNoMatch: item.expectedNoUsefulMatch, candidateRecalled: recalled)
            levels[level, default: .init()].record(rank: acceptedRank, noMatchCorrect: noMatchCorrect, expectedNoMatch: item.expectedNoUsefulMatch, candidateRecalled: recalled)
            results.append(.init(id: item.id, split: item.split, expectedRank: item.expectedRank.rawValue, outcome: outcome, primaryExpectedRank: primaryRank, acceptedRank: acceptedRank, candidateRecalled: recalled, retrievalLimit: evaluated.retrievalLimit, returnedInformationLevel: matches.first?.informationLevel?.rawValue, returnedConfidence: matches.first?.score, candidates: evaluated.candidates.prefix(10).map { .init(species: $0.profile.commonName, rawScore: $0.rawScore, retrievalRelevance: $0.retrievalRelevance, orderingScore: $0.orderingScore, displayScore: $0.score, informationLevel: $0.informationLevel.rawValue, matchedEvidence: $0.matchedEvidence, conflictingEvidence: $0.conflictingEvidence) }, description: revealDescriptions ? item.description : nil))
        }
        return .init(schemaVersion: BenchmarkThresholds.version, engine: engineName, fixture: fixtureName, overall: overall, splits: splits, informationLevels: levels, cases: results)
    }

    private func validateDevelopmentThresholds(_ report: BenchmarkReport) throws {
        struct Breach: Error {}
        let c = report.overall
        let floors = report.engine == "structured" ? BenchmarkThresholds.structuredDevelopment : BenchmarkThresholds.hybridDevelopment
        guard c.positives > 0, c.noMatchCases > 0, report.splits["development"]?.cases == c.cases,
              (report.informationLevels[ObservationInformationLevel.sufficient.rawValue]?.cases ?? 0) > 0,
              (report.informationLevels[ObservationInformationLevel.insufficient.rawValue]?.cases ?? 0) > 0,
              c.top1 >= floors.top1, c.top3 >= floors.top3,
              c.top10 >= floors.top10, c.correctNoMatch == BenchmarkThresholds.developmentNoMatch,
              c.falsePositives == 0, Double(c.candidateRecallHits) / Double(c.positives) >= BenchmarkThresholds.minimumCandidateRecallRate
        else { throw Breach() }
    }

    private func assertDevelopmentThresholds(_ report: BenchmarkReport, file: StaticString = #filePath, line: UInt = #line) {
        let failures = report.cases.filter { $0.outcome.hasPrefix("missed") || $0.outcome == "false-positive" }.map(\.id)
        XCTAssertNoThrow(try validateDevelopmentThresholds(report), "v\(BenchmarkThresholds.version) development gate breached by \(report.engine); failures: \(failures)", file: file, line: line)
    }

    private func assertFrozenThresholds(_ report: BenchmarkReport, file: StaticString = #filePath, line: UInt = #line) {
        let c = report.overall
        XCTAssertGreaterThan(report.splits["development"]?.cases ?? 0, 0, file: file, line: line)
        XCTAssertGreaterThan(report.splits["holdout"]?.cases ?? 0, 0, file: file, line: line)
        XCTAssertGreaterThan(report.informationLevels[ObservationInformationLevel.sufficient.rawValue]?.cases ?? 0, 0, file: file, line: line)
        XCTAssertGreaterThan(report.informationLevels[ObservationInformationLevel.insufficient.rawValue]?.cases ?? 0, 0, file: file, line: line)
        XCTAssertEqual(c.positives, 80, file: file, line: line); XCTAssertEqual(c.noMatchCases, 20, file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.top1, BenchmarkThresholds.frozenTop1, file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.top3, BenchmarkThresholds.frozenTop3, file: file, line: line)
        XCTAssertGreaterThanOrEqual(c.top10, BenchmarkThresholds.frozenTop10, file: file, line: line)
        XCTAssertEqual(c.correctNoMatch, BenchmarkThresholds.frozenNoMatch, file: file, line: line)
        XCTAssertEqual(c.falsePositives, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(Double(c.candidateRecallHits) / Double(c.positives), BenchmarkThresholds.minimumCandidateRecallRate, file: file, line: line)
    }

    private func printReport(_ report: BenchmarkReport) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print("IDENTIFICATION_BENCHMARK_REPORT\n" + String(decoding: try! encoder.encode(report), as: UTF8.self))
    }
}
