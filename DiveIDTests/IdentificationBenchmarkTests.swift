import Foundation
import XCTest
@testable import DiveID

struct IdentificationBenchmarkCase: Codable {
    let id: String
    let split: String
    let description: String
    let selectedPackID: OfflineIdentificationPackID
    let expectedSpeciesIDs: [UUID]
    let acceptableSpeciesIDs: [UUID]
    let informationLevel: ObservationInformationLevel
    let expectedNoUsefulMatch: Bool
    let expectedRank: String
    let notes: String?
}

private struct BenchmarkCounts: Codable, Equatable {
    var total = 0
    var positives = 0
    var top1 = 0
    var top3 = 0
    var top10 = 0
    var noMatch = 0
    var correctNoMatch = 0

    mutating func record(positiveRank: Int?) {
        total += 1; positives += 1
        if let positiveRank {
            if positiveRank <= 1 { top1 += 1 }
            if positiveRank <= 3 { top3 += 1 }
            if positiveRank <= 10 { top10 += 1 }
        }
    }

    mutating func recordNoMatch(correct: Bool) {
        total += 1; noMatch += 1
        if correct { correctNoMatch += 1 }
    }
}

private struct BenchmarkFailure: Codable, Equatable {
    let id: String
    let description: String
    let expectedSpecies: [String]
    let actualRank: Int?
    let topThree: [String]
    let candidates: [Candidate]
    let informationLevel: String

    struct Candidate: Codable, Equatable {
        let species: String
        let rawScore: Double
        let displayScore: Double
        let matchedClues: [String]
        let conflictingClues: [String]
    }
}

private struct BenchmarkReport: Codable, Equatable {
    let overall: BenchmarkCounts
    let splits: [String: BenchmarkCounts]
    let informationLevels: [String: BenchmarkCounts]
    let failures: [BenchmarkFailure]
}

private struct FixtureCatalogRepository: MarineSpeciesCatalogRepository {
    let pack: OfflineIdentificationPack
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        guard id == pack.metadata.id else { throw LocalIdentificationError.catalogUnavailable }
        return pack
    }
}

final class IdentificationBenchmarkTests: XCTestCase {
    private let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private let catalogDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DiveID/Resources/IdentificationPacks/Caribbean")

    private func fixture() throws -> [IdentificationBenchmarkCase] {
        try decode([IdentificationBenchmarkCase].self, at: fixtureDirectory.appendingPathComponent("CaribbeanIdentificationBenchmark.json"))
    }

    private func pack() throws -> OfflineIdentificationPack {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: catalogDirectory.appendingPathComponent("PackManifest.json")))
        let profiles = try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: catalogDirectory.appendingPathComponent("Creatures.json")))
        XCTAssertEqual(profiles.count, metadata.speciesCount)
        return OfflineIdentificationPack(metadata: metadata, profiles: profiles)
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func testBenchmarkFixtureHasUniqueDescriptionsAndRequiredSplit() throws {
        let cases = try fixture()
        XCTAssertEqual(cases.count, 100)
        XCTAssertEqual(Set(cases.map(\.description)).count, cases.count)
        XCTAssertEqual(cases.filter { $0.split == "development" }.count, 70)
        XCTAssertEqual(cases.filter { $0.split == "holdout" }.count, 30)
        XCTAssertTrue(Set(cases.map(\.informationLevel)).isSuperset(of: [.sufficient, .insufficient]))
        XCTAssertTrue(cases.contains(where: \.expectedNoUsefulMatch))
        XCTAssertTrue(Set(cases.map(\.expectedRank)).isSuperset(of: ["top1", "top3", "none"]))
    }

    func testFullBenchmarkIsDeterministicAndReportsMetrics() async throws {
        let first = try await runBenchmark()
        let second = try await runBenchmark()
        XCTAssertEqual(first, second, "Both complete 100-case runs must have identical ordering, scores, metrics, and failures")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        print("CARIBBEAN_BENCHMARK_REPORT\n" + String(decoding: try encoder.encode(first), as: UTF8.self))
    }

    private func runBenchmark() async throws -> BenchmarkReport {
        let catalog = try pack()
        let parser = LocalObservationParser()
        let ranker = LocalSpeciesRanker()
        let service = LocalMarineLifeIdentificationService(catalogRepository: FixtureCatalogRepository(pack: catalog), parser: parser, ranker: ranker)
        let names = Dictionary(uniqueKeysWithValues: catalog.profiles.map { ($0.id, $0.commonName) })
        var overall = BenchmarkCounts()
        var splits: [String: BenchmarkCounts] = [:]
        var levels: [String: BenchmarkCounts] = [:]
        var failures: [BenchmarkFailure] = []

        for item in try fixture() {
            let request = IdentificationRequest(source: .description(item.description), context: .init(region: item.selectedPackID))
            let matches: [IdentificationMatch]
            do {
                matches = try await service.identify(request: request, processedPhoto: nil)
            } catch LocalIdentificationError.regionMismatch {
                matches = []
            }
            let observation = await parser.parse(item.description)
            let ranked = try await ranker.rank(observation: observation, profiles: catalog.profiles)
            let accepted = Set(item.expectedSpeciesIDs + item.acceptableSpeciesIDs)
            let rank = matches.firstIndex { accepted.contains($0.species.id) }.map { $0 + 1 }
            let level = item.informationLevel.rawValue
            let noMatchCorrect = item.expectedNoUsefulMatch && matches.isEmpty

            if item.expectedNoUsefulMatch {
                overall.recordNoMatch(correct: noMatchCorrect)
                splits[item.split, default: BenchmarkCounts()].recordNoMatch(correct: noMatchCorrect)
                levels[level, default: BenchmarkCounts()].recordNoMatch(correct: noMatchCorrect)
            } else {
                overall.record(positiveRank: rank)
                splits[item.split, default: BenchmarkCounts()].record(positiveRank: rank)
                levels[level, default: BenchmarkCounts()].record(positiveRank: rank)
            }

            let expectedLimit = item.expectedRank == "top1" ? 1 : 3
            let failed = item.expectedNoUsefulMatch ? !noMatchCorrect : !(rank.map { $0 <= expectedLimit } ?? false)
            if failed {
                failures.append(BenchmarkFailure(
                    id: item.id,
                    description: item.description,
                    expectedSpecies: item.expectedSpeciesIDs.map { names[$0] ?? $0.uuidString },
                    actualRank: rank,
                    topThree: matches.prefix(3).map { $0.species.commonName },
                    candidates: ranked.prefix(item.expectedNoUsefulMatch ? 10 : 3).map {
                        .init(species: $0.profile.commonName, rawScore: $0.rawScore, displayScore: $0.score, matchedClues: $0.matchedClues, conflictingClues: $0.conflictingClues)
                    },
                    informationLevel: level
                ))
            }
        }
        return BenchmarkReport(overall: overall, splits: splits, informationLevels: levels, failures: failures)
    }
}
