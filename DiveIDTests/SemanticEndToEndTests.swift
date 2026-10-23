import Foundation
import XCTest
@testable import DiveID

/// Proves the real provisioned encoder, not the BM25 fallback, served Global searches, and
/// measures how merging semantic candidates into BM25 changes results. Skipped unless the
/// semantic-search workflow supplies provisioned artifacts:
///
/// * `DIVEID_SEMANTIC_RESOURCES` names a directory holding `Semantic-global.*` (SwiftPM).
/// * `DIVEID_REQUIRE_SEMANTIC=1` requires them in the built application bundle (Xcode).
///
/// `DIVEID_SEMANTIC_REPORT` optionally names a JSON report file. Quality is not asserted:
/// the encoder is unapproved and the V05 descriptions are development data only.
final class SemanticEndToEndTests: XCTestCase {
    private struct Case: Decodable { let id: String; let description: String; let kind: String }
    private struct Fixture: Decodable { let cases: [Case] }

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func globalPack() async throws -> OfflineIdentificationPack {
        // Debug and Internal open the development catalogue; the encoder is indexed against it.
        try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly,
                                                       access: .experimentalDevelopment).loadPack(id: .global)
    }

    private func locations(packID: OfflineIdentificationPackID) throws -> SemanticArtifactLocations {
        if let path = environment["DIVEID_SEMANTIC_RESOURCES"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            let stem = "Semantic-\(packID.rawValue)"
            return SemanticArtifactLocations(
                contractURL: directory.appendingPathComponent("\(stem).contract.json"),
                compiledModelURL: directory.appendingPathComponent("\(stem).mlmodelc", isDirectory: true),
                vocabularyURL: directory.appendingPathComponent("\(stem).vocab.json"),
                indexURL: directory.appendingPathComponent("\(stem).index.json"))
        }
        if environment["DIVEID_REQUIRE_SEMANTIC"] == "1" {
            return try SemanticArtifactLocations.bundled(packID: packID, bundle: TestResources.productionBundle)
        }
        throw XCTSkip("Set DIVEID_SEMANTIC_RESOURCES or DIVEID_REQUIRE_SEMANTIC=1 with provisioned Semantic-global artifacts.")
    }

    private func mergedEngine(pack: OfflineIdentificationPack, diagnostics: SemanticDiagnosticsStore,
                              runtime: SemanticRetrievalRuntime) throws -> HybridDescriptionSearchEngine {
        let semantic = ExperimentalSemanticRetriever(pack: pack.metadata, locations: try locations(packID: pack.metadata.id),
                                                     runtime: runtime, fallback: NoCandidateRetriever(), diagnostics: diagnostics)
        return HybridDescriptionSearchEngine(semanticComplement: semantic)
    }

    /// Hosted in the app: the bundled artifacts load through the same selection the app uses.
    func testBundledArtifactsServeTheExperimentalSelection() async throws {
        guard environment["DIVEID_REQUIRE_SEMANTIC"] == "1" else {
            throw XCTSkip("Set DIVEID_REQUIRE_SEMANTIC=1 to require bundled Semantic-global artifacts.")
        }
        let pack = try await globalPack()
        let diagnostics = SemanticDiagnosticsStore()
        let engine = ConfiguredDescriptionSearchEngine(selection: .experimentalCoreML, bundle: TestResources.productionBundle,
                                                       diagnostics: diagnostics)
        let result = try await engine.search(description: "large flat ray with white spots on a dark back gliding over sand", pack: pack)
        let recorded = await diagnostics.latest
        let metric = try XCTUnwrap(recorded)
        XCTAssertEqual(metric.actualEngine, .experimentalCoreML, "fell back: \(metric.fallbackReason?.description ?? "unknown")")
        XCTAssertNil(metric.fallbackReason)
        XCTAssertFalse(result.candidates.isEmpty)
    }

    func testProvisionedEncoderComplementsBM25OnGlobal() async throws {
        let pack = try await globalPack()
        _ = try locations(packID: pack.metadata.id)
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "V05Development.v2")))
        let diagnostics = SemanticDiagnosticsStore()
        let merged = try mergedEngine(pack: pack, diagnostics: diagnostics, runtime: SemanticRetrievalRuntime())
        let bm25 = HybridDescriptionSearchEngine()

        var rows: [[String: Any]] = []
        var topChanged = 0, semanticOnlyShown = 0, noMatchGainedResults = 0
        for item in fixture.cases {
            let lexical = try await bm25.search(description: item.description, pack: pack)
            let combined = try await merged.search(description: item.description, pack: pack)
            let recorded = await diagnostics.latest
            let metric = try XCTUnwrap(recorded)
            XCTAssertEqual(metric.actualEngine, .experimentalCoreML,
                           "\(item.id) fell back: \(metric.fallbackReason?.description ?? "unknown")")
            XCTAssertNil(metric.fallbackReason, item.id)

            // Merging must never change how a BM25-retrieved species is scored.
            let lexicalByID = Dictionary(uniqueKeysWithValues: lexical.candidates.map { ($0.profile.id, $0) })
            for candidate in combined.candidates {
                guard let original = lexicalByID[candidate.profile.id] else { continue }
                XCTAssertEqual(candidate.rawScore, original.rawScore, "\(item.id) \(candidate.profile.commonName)")
                XCTAssertEqual(candidate.score, original.score, "\(item.id) \(candidate.profile.commonName)")
            }
            // Every BM25 candidate stays in the pool.
            XCTAssertTrue(Set(lexical.retrievedSpeciesIDs).isSubset(of: Set(combined.retrievedSpeciesIDs)), item.id)

            let additions = combined.candidates.filter { lexicalByID[$0.profile.id] == nil }.count
            let changed = lexical.candidates.first?.profile.id != combined.candidates.first?.profile.id
            if changed { topChanged += 1 }
            if additions > 0 { semanticOnlyShown += 1 }
            if item.kind == "noMatch", lexical.candidates.isEmpty, !combined.candidates.isEmpty { noMatchGainedResults += 1 }
            rows.append([
                "id": item.id, "kind": item.kind,
                "bm25Top1": lexical.candidates.first?.profile.commonName ?? "",
                "mergedTop1": combined.candidates.first?.profile.commonName ?? "",
                "bm25ResultCount": lexical.candidates.count, "mergedResultCount": combined.candidates.count,
                "semanticOnlyInResults": additions,
                "embeddingMilliseconds": metric.embeddingMilliseconds, "loadMilliseconds": metric.loadMilliseconds,
                "totalSemanticMilliseconds": metric.totalMilliseconds,
            ])
        }
        if let path = environment["DIVEID_SEMANTIC_REPORT"] {
            let report: [String: Any] = [
                "schemaVersion": 1, "fixture": "V05Development.v2", "pack": "\(pack.metadata.id.rawValue):\(pack.metadata.packVersion)",
                "speciesCount": pack.profiles.count, "cases": fixture.cases.count,
                "top1Changed": topChanged, "casesWithSemanticOnlyResults": semanticOnlyShown,
                "noMatchCasesThatGainedResults": noMatchGainedResults, "rows": rows,
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
