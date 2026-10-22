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
        var composed = global.metadata
        composed.speciesCount += caribbean.profiles.count
        let variants: [(String, OfflineIdentificationPack)] = [
            ("global-as-written", global),
            ("global-plus-caribbean-8 (in memory only)", OfflineIdentificationPack(metadata: composed, profiles: global.profiles + caribbean.profiles)),
            // Diagnostic: Global's rebuilt text at regional size, separating text effects from scale effects.
            ("global-records-for-tropical-pacific-ids (diagnostic)", OfflineIdentificationPack(metadata: subsetMetadata, profiles: subsetProfiles))
        ]
        var groups: [[String: Any]] = []
        for (name, pack) in variants {
            let service = LocalMarineLifeIdentificationService(catalogRepository: InMemoryCatalog(pack: pack),
                searchEngine: ConfiguredDescriptionSearchEngine(selection: .productionDefault, bundle: TestResources.productionBundle))
            let known = Set(pack.profiles.map(\.id))
            var tally: [String: (hits: Int, total: Int)] = [:]
            func count(_ key: String, _ hit: Bool) { tally[key, default: (0, 0)].total += 1; if hit { tally[key, default: (0, 0)].hits += 1 } }
            var rows: [[String: Any]] = [], blocked: [String] = [], byRegion: [String: [String: Int]] = [:]
            for item in fixture.cases {
                let accepted = Set((item.expectedSpeciesIDs + item.acceptableSpeciesIDs).map { kept[$0] ?? $0 })
                if !accepted.isEmpty && accepted.isDisjoint(with: known) { blocked.append(item.id); continue }
                var matches: [IdentificationMatch] = [], failure: String? = nil
                do {
                    matches = try await service.identify(request: .init(source: .description(item.description), context: .init(region: .global)), processedPhoto: nil)
                } catch { failure = String(describing: error) }
                let rank = matches.firstIndex { accepted.contains($0.species.id) }.map { $0 + 1 }
                let confidenceOK = matches.allSatisfy { $0.score.isFinite && (0...item.maximumConfidence).contains($0.score) && ($0.informationLevel != .limited || $0.score <= 0.64) }
                count("confidenceCompliant", confidenceOK)
                var outcome = "evaluated"
                switch item.kind {
                case "identification":
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
            let gates = floors.keys.sorted().compactMap { key -> [String: Any]? in
                guard let value = tally[key] else { return nil }
                return ["metric": key, "hits": value.hits, "denominator": value.total, "minimumRate": floors[key]!,
                        "status": value.total == 0 ? "not-evaluated" : (Double(value.hits) / Double(value.total) >= floors[key]! ? "passed" : "failed")]
            }
            groups.append(["variant": name, "packSize": pack.profiles.count, "coverageBlockedCases": blocked, "gates": gates,
                           "counts": tally.mapValues { ["hits": $0.hits, "total": $0.total] }, "byRegion": byRegion, "cases": rows])
            print("GLOBAL_EVALUATION \(name) size=\(pack.profiles.count) blocked=\(blocked.count) " + gates.map { "\($0["metric"]!)=\($0["hits"]!)/\($0["denominator"]!):\($0["status"]!)" }.joined(separator: " "))
            XCTAssertTrue(rows.allSatisfy { ($0["error"] as? String) == nil || ($0["kind"] as? String) == "noMatch" }, "\(name): the service must not fail on Global")
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

    /// Location is a ranking signal, never a filter: describing a species from outside
    /// its recorded range must keep it a candidate, with the same eligibility score and
    /// confidence and a lower ordering. Whether it stays in the displayed top 10 is
    /// reported, not asserted: the approved -3 penalty can move a marginal species below it.
    func testOutOfRangeLocationCluesStillReturnTheSpecies() async throws {
        let fixture = try JSONDecoder().decode(LocationFixture.self, from: Data(contentsOf: TestResources.fixture(named: "GlobalLocation.v1")))
        let pack = try await repository().loadPack(id: .global)
        let engine = HybridDescriptionSearchEngine()
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 6)
        var displayedBefore = 0, displayedAfter = 0
        for item in fixture.cases {
            XCTAssertTrue(pack.profiles.contains { $0.id == item.speciesID }, "\(item.id): species missing from Global")
            let plain = try await engine.search(description: item.description, pack: pack).candidates
            let located = try await engine.search(description: item.description + ". " + item.outOfRangeLocation, pack: pack).candidates
            let before = plain.firstIndex { $0.profile.id == item.speciesID }, after = located.firstIndex { $0.profile.id == item.speciesID }
            print("GLOBAL_LOCATION \(item.id) rank without location=\(before.map { "\($0 + 1)" } ?? "-") with=\(after.map { "\($0 + 1)" } ?? "-") of \(located.count)")
            guard let before else { XCTFail("\(item.id): not a candidate even without a location; the case is invalid"); continue }
            guard let after else { XCTFail("\(item.id): an out-of-range location removed the species from the candidates"); continue }
            XCTAssertEqual(located[after].rawScore, plain[before].rawScore, accuracy: 1e-9, "\(item.id): location must not change eligibility")
            XCTAssertEqual(located[after].score, plain[before].score, accuracy: 1e-9, "\(item.id): location must not change confidence")
            XCTAssertLessThan(located[after].orderingScore, plain[before].orderingScore, "\(item.id): out-of-range ordering is lowered")
            if before < 10 { displayedBefore += 1; if after < 10 { displayedAfter += 1 } else { print("GLOBAL_LOCATION \(item.id) left the displayed top 10") } }
        }
        print("GLOBAL_LOCATION displayed (top 10) without location=\(displayedBefore) with=\(displayedAfter)")
    }
}
