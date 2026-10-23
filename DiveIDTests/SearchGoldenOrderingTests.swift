import Foundation
import XCTest
@testable import DiveID

/// Golden search outputs (Fixtures/SearchGolden.v2.json). v1 was captured at commit a687477,
/// before the BM25 index and lazy pack listing, which reproduced it exactly. v2 was
/// regenerated for the intended ranking change of Docs/HybridRankingContract.md
/// ("Group names and appearance variants") and the builder v4 Global content; the
/// change is described in Docs/GlobalPackEvaluation.md. Its "global" entries were
/// regenerated again when the Caribbean pack's 8 records were added to Global; every
/// regional entry was unchanged. Every development query of the
/// evaluation fixtures (the frozen Caribbean holdout stays closed) is run against each
/// pack; ranks and scores must match exactly, scores to 1e-9.
/// Set DIVEID_WRITE_SEARCH_GOLDEN=<path> to write a new golden file instead of comparing.
final class SearchGoldenOrderingTests: XCTestCase {
    private struct Described: Decodable { let id: String; let description: String; let split: String? }
    private struct Cases: Decodable { let cases: [Described] }
    private struct Location: Decodable { let id: String; let description: String; let outOfRangeLocation: String }
    private struct LocationCases: Decodable { let cases: [Location] }

    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    /// Unique descriptions, in a fixed order.
    private func queries() throws -> [String] {
        let decoder = JSONDecoder()
        var texts: [String] = []
        for name in ["CaribbeanIdentificationBenchmark", "CaribbeanLimitedDescriptions.v1", "TropicalPacificDiverDescriptions.v1"] {
            texts += try decoder.decode([Described].self, from: Data(contentsOf: TestResources.fixture(named: name)))
                .filter { $0.split != "holdout" }.map(\.description)
        }
        for name in ["V05Development.v1", "V05Development.v2"] {
            texts += try decoder.decode(Cases.self, from: Data(contentsOf: TestResources.fixture(named: name))).cases.map(\.description)
        }
        for item in try decoder.decode(LocationCases.self, from: Data(contentsOf: TestResources.fixture(named: "GlobalLocation.v1"))).cases {
            texts += [item.description, item.description + ". " + item.outOfRangeLocation]
        }
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }
    }

    private func packs() async throws -> [(String, OfflineIdentificationPack)] {
        func repository(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) -> BundleMarineSpeciesCatalogRepository {
            BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access)
        }
        let global = try await repository(.experimentalDevelopment).loadPack(id: .global)
        // The 250 records of Global batch 1: the size of the approved Release subset.
        let manifests = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Data/CatalogReview/GlobalBatches/batch-01"), includingPropertiesForKeys: nil)
        let manifest = try XCTUnwrap(manifests.first { $0.lastPathComponent.hasPrefix("manifest-g1-") })
        let records = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])?["records"] as? [[String: Any]])
        let batch = Set(records.compactMap { ($0["speciesID"] as? String).flatMap(UUID.init(uuidString:)) })
        var subset = global.metadata
        let subsetProfiles = global.profiles.filter { batch.contains($0.id) }
        subset.speciesCount = subsetProfiles.count
        return [
            ("caribbean", try await repository(.experimentalDevelopment).loadPack(id: .caribbean)),
            ("caribbean-release", try await repository(.publication).loadPack(id: .caribbean)),
            ("tropical-pacific", try await repository(.experimentalDevelopment).loadPack(id: .tropicalPacific)),
            ("global", global),
            ("global-batch-01", OfflineIdentificationPack(metadata: subset, profiles: subsetProfiles))
        ]
    }

    private func outputs(_ pack: OfflineIdentificationPack, _ index: BM25Index, _ query: String) async throws -> [String: Any] {
        let result = try await HybridDescriptionSearchEngine().search(description: query, pack: pack)
        let pool = try await BM25SpeciesCandidateRetriever().retrieve(query: query, index: index, limit: 50)
        return [
            "ranked": result.candidates.map { ["id": $0.profile.id.uuidString, "raw": $0.rawScore, "ordering": $0.orderingScore,
                                                "score": $0.score, "relevance": $0.retrievalRelevance ?? -1] as [String: Any] },
            "retrieved": result.retrievedSpeciesIDs.map(\.uuidString),
            "pool": pool.map { ["id": $0.speciesID.uuidString, "score": $0.retrievalScore, "evidence": $0.evidence.rawValue] as [String: Any] }
        ]
    }

    func testSearchOrderingMatchesTheGoldenOutputs() async throws {
        let queries = try queries()
        let packs = try await packs()
        let builder = SpeciesSearchDocumentBuilder()
        func documents(_ pack: OfflineIdentificationPack) -> [SpeciesSearchDocument] { pack.profiles.map { builder.document(from: $0, pack: pack.metadata) } }
        if let path = ProcessInfo.processInfo.environment["DIVEID_WRITE_SEARCH_GOLDEN"] {
            var document: [String: Any] = ["schemaVersion": 1, "queries": queries]
            for (name, pack) in packs {
                var rows: [[String: Any]] = []
                let index = BM25Index(documents: documents(pack))
                for query in queries { rows.append(try await outputs(pack, index, query)) }
                document[name] = rows
            }
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: URL(fileURLWithPath: path))
            return
        }
        let golden = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: TestResources.fixture(named: "SearchGolden.v2"))) as? [String: Any])
        XCTAssertEqual(golden["queries"] as? [String], queries, "the golden file covers exactly these queries")
        var compared = 0
        for (name, pack) in packs {
            let expected = try XCTUnwrap(golden[name] as? [[String: Any]], name)
            let docs = documents(pack)
            let bm25 = BM25Index(documents: docs)
            // The documents-based entry point (used by the experimental semantic fallback)
            // builds the same index, so it must return the same pool.
            for query in queries.prefix(5) {
                let viaDocuments = try await BM25SpeciesCandidateRetriever().retrieve(query: query, documents: docs, limit: 50)
                let viaIndex = try await BM25SpeciesCandidateRetriever().retrieve(query: query, index: bm25, limit: 50)
                XCTAssertEqual(viaDocuments, viaIndex, "\(name) / \(query)")
            }
            for (position, query) in queries.enumerated() {
                let actual = try await outputs(pack, bm25, query)
                let want = expected[position]
                let label = "\(name) / \(query)"
                XCTAssertEqual(actual["retrieved"] as? [String], want["retrieved"] as? [String], "\(label): retrieved pool order")
                for key in ["ranked", "pool"] {
                    let a = try XCTUnwrap(actual[key] as? [[String: Any]]), w = try XCTUnwrap(want[key] as? [[String: Any]])
                    XCTAssertEqual(a.map { $0["id"] as? String }, w.map { $0["id"] as? String }, "\(label): \(key) ranks")
                    for (x, y) in zip(a, w) {
                        for field in ["raw", "ordering", "score", "relevance"] where x[field] != nil {
                            XCTAssertEqual(x[field] as! Double, (y[field] as! NSNumber).doubleValue, accuracy: 1e-9, "\(label): \(key) \(field)")
                        }
                        if let evidence = x["evidence"] as? String { XCTAssertEqual(evidence, y["evidence"] as? String, label) }
                    }
                }
                compared += 1
            }
        }
        XCTAssertEqual(compared, queries.count * packs.count)
        print("SEARCH_GOLDEN compared \(compared) query results across \(packs.count) packs")
    }
}
