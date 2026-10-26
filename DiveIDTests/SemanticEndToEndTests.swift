import Foundation
import XCTest
@testable import DiveID

/// Proves the real provisioned encoder serves the experimental semantic fallback on Global
/// (it runs only when BM25 ranks nothing) and measures what the fallback shows. Skipped
/// unless provisioned artifacts are supplied:
///
/// * `DIVEID_SEMANTIC_RESOURCES` names a directory holding `Semantic-global.*` (SwiftPM).
/// * `DIVEID_REQUIRE_SEMANTIC=1` requires them in the built application bundle (Xcode).
///
/// `DIVEID_SEMANTIC_REPORT` and `DIVEID_SEMANTIC_DISTRIBUTION` optionally name JSON report
/// files. A no-match description gaining any result is a hard failure; quality is reported,
/// not asserted, because the encoder is unapproved and the cases are development data.
final class SemanticEndToEndTests: XCTestCase {

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

    private func fallbackEngine(locations: SemanticArtifactLocations, diagnostics: SemanticDiagnosticsStore,
                                runtime: SemanticRetrievalRuntime) -> ConfiguredDescriptionSearchEngine {
        ConfiguredDescriptionSearchEngine(selection: .experimentalCoreML, runtime: runtime, diagnostics: diagnostics,
                                          locateArtifacts: { _ in locations })
    }

    /// Hosted in the app: the bundled artifacts load through the same selection the app uses,
    /// and Core ML serves the fallback on development descriptions BM25 cannot answer.
    func testBundledArtifactsServeTheExperimentalSelection() async throws {
        guard environment["DIVEID_REQUIRE_SEMANTIC"] == "1" else {
            throw XCTSkip("Set DIVEID_REQUIRE_SEMANTIC=1 to require bundled Semantic-global artifacts.")
        }
        let pack = try await globalPack()
        let diagnostics = SemanticDiagnosticsStore()
        let engine = ConfiguredDescriptionSearchEngine(selection: .experimentalCoreML, bundle: TestResources.productionBundle,
                                                       diagnostics: diagnostics)
        let bm25 = HybridDescriptionSearchEngine()
        var served = 0
        for item in try developmentCases() where item.kind == "identification" {
            guard try await bm25.search(description: item.description, pack: pack).candidates.isEmpty else { continue }
            let result = try await engine.search(description: item.description, pack: pack)
            let recorded = await diagnostics.latest
            let metric = try XCTUnwrap(recorded)
            XCTAssertNil(metric.fallbackReason, "\(item.id): bundled artifacts failed: \(metric.fallbackReason?.description ?? "")")
            if metric.fallbackOutcome == .served {
                served += 1
                XCTAssertEqual(metric.actualEngine, .experimentalCoreML, item.id)
                XCTAssertFalse(result.candidates.isEmpty, item.id)
                print("SEMANTIC-ENGINE case=\(item.id) requested=\(metric.requestedEngine.rawValue) actual=\(metric.actualEngine.rawValue) "
                      + "outcome=\(metric.fallbackOutcome.rawValue) model=\(metric.modelIdentity ?? "none")")
            }
        }
        XCTAssertGreaterThan(served, 0, "Core ML never served a fallback from the bundled artifacts")
    }

#if canImport(CoreML)
    /// `Semantic-<pack>.parity.json`, written by provisioning: the pinned tokenizer's encodings,
    /// the float32 reference vectors and reference top-k for each frozen probe, and the
    /// tolerances frozen in Tools/SemanticSearch/coreml-parity.v1.json.
    private struct ParityFixture: Decodable {
        struct Tolerances: Decodable {
            let coreMLCosineMinimum: Double
            let coreMLMaxAbsoluteDifference: Double
            let unitNormMaxDeviation: Double
            let retrievalTopK: Int
            let retrievalTopKOverlapMinimum: Int
            let retrievalScoreMaxAbsoluteDifference: Double
            let retrievalTop1RequiredWhenReferenceMarginAtLeast: Double
        }
        struct Probe: Decodable {
            let text: String
            let inputIDs: [Int32]
            let attentionMask: [Int32]
            let referenceVector: [Double]
            let referenceTopK: [String]
            let referenceTopKScores: [Double]
            let referenceTop1Margin: Double?
        }
        let schemaVersion: Int
        let tolerances: Tolerances
        let probes: [Probe]
    }

    private func parityFixtureURL(packID: OfflineIdentificationPackID) throws -> URL {
        let stem = "Semantic-\(packID.rawValue)"
        if let path = environment["DIVEID_SEMANTIC_RESOURCES"] {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("\(stem).parity.json")
        }
        return try XCTUnwrap(TestResources.productionBundle.url(forResource: stem, withExtension: "parity.json"),
                             "\(stem).parity.json is not in the application bundle")
    }

    /// The app's own tokenizer, Core ML encoder, pooling and retrieval against the provisioning
    /// reference, within the frozen tolerances. Runs on the artifacts the app loads (SwiftPM:
    /// the packaged directory; hosted: the built application bundle).
    func testAppEncoderMatchesTheProvisioningReference() async throws {
        let pack = try await globalPack()
        let locations = try locations(packID: pack.metadata.id)
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: Data(contentsOf: try parityFixtureURL(packID: pack.metadata.id)))
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertFalse(fixture.probes.isEmpty)
        let contract = try JSONDecoder().decode(SemanticModelArtifactContract.self, from: Data(contentsOf: locations.contractURL))
        let vocabulary = try Data(contentsOf: locations.vocabularyURL)
        let tokenizer = try WordPieceTokenizer(data: vocabulary, contract: contract)
        let provider = try await CoreMLSemanticEmbeddingProvider.load(compiledModelURL: locations.compiledModelURL,
                                                                      contract: contract, vocabularyData: vocabulary)
        let documents = try await SearchIndexStore.shared.documents(pack: pack, builder: SpeciesSearchDocumentBuilder())
        let runtime = SemanticRetrievalRuntime()
        let tolerance = fixture.tolerances
        var minimumCosine = Double.infinity, maximumDifference = 0.0, minimumOverlap = Int.max, top1Agreement = 0
        for (number, probe) in fixture.probes.enumerated() {
            let label = "probe \(number)"
            // Tokenizer parity with the pinned tokenizer, padding and truncation included.
            let encoded = tokenizer.encode(probe.text)
            XCTAssertEqual(encoded.ids, probe.inputIDs, "\(label) token IDs")
            XCTAssertEqual(encoded.mask, probe.attentionMask, "\(label) attention mask")

            // Core ML (masked mean pooling, L2 normalization) against the float32 reference.
            let vector = try await provider.embedding(for: probe.text).map(Double.init)
            XCTAssertEqual(vector.count, probe.referenceVector.count, label)
            let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            let referenceNorm = sqrt(probe.referenceVector.reduce(0) { $0 + $1 * $1 })
            let cosine = zip(vector, probe.referenceVector).reduce(0) { $0 + $1.0 * $1.1 } / (norm * referenceNorm)
            let difference = zip(vector, probe.referenceVector).map { abs($0 - $1) }.max() ?? .infinity
            minimumCosine = min(minimumCosine, cosine); maximumDifference = max(maximumDifference, difference)
            XCTAssertGreaterThanOrEqual(cosine, tolerance.coreMLCosineMinimum, "\(label) cosine")
            XCTAssertLessThanOrEqual(difference, tolerance.coreMLMaxAbsoluteDifference, "\(label) largest difference")
            XCTAssertLessThanOrEqual(abs(norm - 1), tolerance.unitNormMaxDeviation, "\(label) norm")

            // Retrieval over the bundled index against the reference ranking.
            let expected = probe.referenceTopK.compactMap(UUID.init(uuidString:))
            XCTAssertEqual(expected.count, probe.referenceTopK.count, "\(label) reference IDs")
            let retrieved = try await runtime.retrieve(locations: locations, pack: pack.metadata, documents: documents,
                                                       query: probe.text, limit: tolerance.retrievalTopK).candidates
            let overlap = Set(retrieved.map(\.speciesID)).intersection(expected).count
            minimumOverlap = min(minimumOverlap, overlap)
            XCTAssertGreaterThanOrEqual(overlap, min(tolerance.retrievalTopKOverlapMinimum, expected.count), "\(label) top-k overlap")
            for (speciesID, score) in zip(expected, probe.referenceTopKScores) {
                guard let found = retrieved.first(where: { $0.speciesID == speciesID }) else { continue }
                XCTAssertLessThanOrEqual(abs(found.retrievalScore - score), tolerance.retrievalScoreMaxAbsoluteDifference,
                                         "\(label) score for \(speciesID)")
            }
            if retrieved.first?.speciesID == expected.first { top1Agreement += 1 }
            if let margin = probe.referenceTop1Margin, margin >= tolerance.retrievalTop1RequiredWhenReferenceMarginAtLeast {
                XCTAssertEqual(retrieved.first?.speciesID, expected.first, "\(label) top-1")
            }
        }
        let summary: [String: Any] = ["probes": fixture.probes.count, "minimumCosine": minimumCosine,
                                      "maximumAbsoluteDifference": maximumDifference, "minimumTopKOverlap": minimumOverlap,
                                      "top1Agreement": top1Agreement]
        print("SEMANTIC-PARITY " + String(decoding: try JSONSerialization.data(withJSONObject: Self.finite(summary), options: [.sortedKeys]), as: UTF8.self))
    }
#endif

    /// Development descriptions only: the V05 v2 cases and the benchmark's development split.
    /// The benchmark holdout is never read here.
    private func developmentCases() throws -> [(id: String, description: String, kind: String, expected: [UUID])] {
        struct V05: Decodable { let id: String; let description: String; let kind: String; let expectedSpeciesIDs: [UUID] }
        struct V05Fixture: Decodable { let cases: [V05] }
        let v05 = try JSONDecoder().decode(V05Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "V05Development.v2")))
        let benchmark = try JSONDecoder().decode([IdentificationBenchmarkCase].self,
                                                 from: Data(contentsOf: TestResources.fixture(named: "CaribbeanIdentificationBenchmark")))
        return v05.cases.map { ($0.id, $0.description, $0.kind, $0.expectedSpeciesIDs) }
            + benchmark.filter { $0.split == "development" }.map {
                ($0.id, $0.description, $0.expectedNoUsefulMatch ? "noMatch" : "identification", $0.expectedSpeciesIDs)
            }
    }

    /// JSONSerialization rejects NaN; an empty statistic is written as null.
    private static func finite(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.mapValues { value in (value as? Double).map { $0.isFinite ? $0 as Any : NSNull() as Any } ?? value }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    /// Raw cosine distribution over all Global species, for calibrating the semantic floor.
    func testReportsGlobalCosineDistribution() async throws {
        let pack = try await globalPack()
        let locations = try locations(packID: pack.metadata.id)
        let documents = try await SearchIndexStore.shared.documents(pack: pack, builder: SpeciesSearchDocumentBuilder())
        let runtime = SemanticRetrievalRuntime()
        var rows: [[String: Any]] = []
        var noMatchTop1: [Double] = [], expectedCosines: [Double] = [], backgroundP99: [Double] = [], top10: [Double] = []
        for item in try developmentCases() {
            let all = try await runtime.retrieve(locations: locations, pack: pack.metadata, documents: documents,
                                                 query: item.description, limit: documents.count).candidates
            let scores = all.map(\.retrievalScore)
            let ascending = scores.sorted()
            let expectedRank = all.firstIndex { item.expected.contains($0.speciesID) }
            if item.kind == "noMatch" { noMatchTop1.append(scores.first ?? .nan) }
            if let expectedRank { expectedCosines.append(scores[expectedRank]) }
            backgroundP99.append(Self.percentile(ascending, 0.99))
            if scores.count >= 10 { top10.append(scores[9]) }
            rows.append(["id": item.id, "kind": item.kind, "top1": scores.first ?? .nan, "top10": scores.count >= 10 ? scores[9] : .nan,
                         "p50": Self.percentile(ascending, 0.5), "p99": Self.percentile(ascending, 0.99),
                         "expectedCosine": expectedRank.map { scores[$0] as Any } ?? NSNull(),
                         "expectedSemanticRank": expectedRank.map { ($0 + 1) as Any } ?? NSNull()])
        }
        let summary: [String: Any] = [
            "cases": rows.count, "noMatchCases": noMatchTop1.count, "positivesWithExpectedInGlobal": expectedCosines.count,
            "noMatchTop1Max": noMatchTop1.max() ?? .nan, "noMatchTop1Median": Self.percentile(noMatchTop1.sorted(), 0.5),
            "expectedCosineMin": expectedCosines.min() ?? .nan, "expectedCosineMedian": Self.percentile(expectedCosines.sorted(), 0.5),
            "expectedCosineP25": Self.percentile(expectedCosines.sorted(), 0.25),
            "backgroundP99Median": Self.percentile(backgroundP99.sorted(), 0.5), "tenthBestMedian": Self.percentile(top10.sorted(), 0.5),
            "semanticFallbackCosine": LocalRankingWeights().semanticFallbackCosine,
        ]
        let data = try JSONSerialization.data(withJSONObject: Self.finite(summary), options: [.sortedKeys])
        print("SEMANTIC-CALIBRATION " + String(decoding: data, as: UTF8.self))
        if let path = environment["DIVEID_SEMANTIC_DISTRIBUTION"] {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "summary": Self.finite(summary), "rows": rows.map(Self.finite)],
                                       options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
    }

    /// The fallback design on Global: BM25-answered cases are returned unchanged without the
    /// model; the fallback runs only where BM25 ranks nothing; no no-match description may gain a
    /// result. Reports where it fired, what it rescued, what it showed wrongly and its latency.
    func testProvisionedEncoderFallsBackOnlyWhenBM25FindsNothing() async throws {
        let pack = try await globalPack()
        let locations = try locations(packID: pack.metadata.id)
        let cases = try developmentCases()
        let documents = try await SearchIndexStore.shared.documents(pack: pack, builder: SpeciesSearchDocumentBuilder())
        let diagnostics = SemanticDiagnosticsStore()
        let runtime = SemanticRetrievalRuntime()
        let engine = fallbackEngine(locations: locations, diagnostics: diagnostics, runtime: runtime)
        let bm25 = HybridDescriptionSearchEngine()
        let cutoff = LocalRankingWeights().semanticFallbackCosine

        var rows: [[String: Any]] = []
        var outcomes: [String: Int] = [:], wrongByKind: [String: Int] = [:]
        var noMatchGainedResults = 0, rescued = 0, rescuedFirst = 0, maximumFallbackConfidence = Double.nan
        var firedLoad: [Double] = [], firedEmbedding: [Double] = [], firedTotal: [Double] = []
        for item in cases {
            let lexical = try await bm25.search(description: item.description, pack: pack)
            let result = try await engine.search(description: item.description, pack: pack)
            let recorded = await diagnostics.latest
            let metric = try XCTUnwrap(recorded)
            XCTAssertEqual(metric.requestedEngine, .experimentalCoreML, item.id)
            XCTAssertNil(metric.fallbackReason, "\(item.id): artifacts failed: \(metric.fallbackReason?.description ?? "")")
            outcomes[metric.fallbackOutcome.rawValue, default: 0] += 1
            var row: [String: Any] = ["id": item.id, "kind": item.kind, "bm25Abstained": lexical.candidates.isEmpty,
                                      "fallbackOutcome": metric.fallbackOutcome.rawValue,
                                      "expectedTop1BM25": lexical.candidates.first.map { item.expected.contains($0.profile.id) } ?? false,
                                      "expectedTop1": result.candidates.first.map { item.expected.contains($0.profile.id) } ?? false]
            if !lexical.candidates.isEmpty {
                // BM25 answered: the result is BM25's, unchanged, and the model was not used.
                XCTAssertEqual(metric.fallbackOutcome, .notNeeded, item.id)
                XCTAssertNil(metric.modelIdentity, item.id)
                XCTAssertEqual(result.candidates.map(\.profile.id), lexical.candidates.map(\.profile.id), item.id)
                XCTAssertEqual(result.candidates.map(\.score), lexical.candidates.map(\.score), item.id)
                rows.append(row)
                continue
            }
            // BM25 ranked nothing: the measurement behind the cutoff, then what the fallback showed.
            let similar = try await runtime.retrieve(locations: locations, pack: pack.metadata, documents: documents,
                                                     query: item.description, limit: documents.count).candidates
            let expectedRank = similar.firstIndex { item.expected.contains($0.speciesID) }
            row["topSemanticCosine"] = similar.first?.retrievalScore ?? .nan
            row["topSemanticIsExpected"] = similar.first.map { item.expected.contains($0.speciesID) } ?? false
            row["expectedSemanticRank"] = expectedRank.map { ($0 + 1) as Any } ?? NSNull()
            row["expectedCosine"] = expectedRank.map { similar[$0].retrievalScore as Any } ?? NSNull()
            row["candidatesAboveCutoff"] = similar.filter { $0.retrievalScore >= cutoff }.count
            let shownExpected = result.candidates.firstIndex { item.expected.contains($0.profile.id) }
            let wrong = result.candidates.filter { !item.expected.contains($0.profile.id) }
            row["fallbackResultCount"] = result.candidates.count
            row["expectedFallbackRank"] = shownExpected.map { ($0 + 1) as Any } ?? NSNull()
            row["wrongFallbackResults"] = wrong.count
            row["maximumFallbackConfidence"] = result.candidates.map(\.score).max() ?? .nan
            if item.kind == "noMatch" {
                // Hard gate: no no-match description may gain a result.
                if !result.candidates.isEmpty { noMatchGainedResults += 1 }
                XCTAssertTrue(result.candidates.isEmpty, "\(item.id) gained fallback results: \(result.candidates.map(\.profile.commonName))")
            }
            if metric.fallbackOutcome == .served {
                XCTAssertEqual(metric.actualEngine, .experimentalCoreML, item.id)
                for candidate in result.candidates {
                    XCTAssertEqual(candidate.informationLevel, .limited, item.id)
                    XCTAssertLessThanOrEqual(candidate.score, LocalRankingWeights.limitedConfidenceCap, item.id)
                    XCTAssertTrue(candidate.matchedEvidence.contains(LocalRankingWeights.similarityClue), item.id)
                }
                if shownExpected != nil { rescued += 1 }
                if shownExpected == 0 { rescuedFirst += 1 }
                wrongByKind[item.kind, default: 0] += wrong.count
                if let confidence = result.candidates.map(\.score).max() {
                    maximumFallbackConfidence = maximumFallbackConfidence.isNaN ? confidence : max(maximumFallbackConfidence, confidence)
                }
            }
            if metric.fallbackOutcome == .served || metric.fallbackOutcome == .nothingAboveCutoff {
                // Latency only where the fallback actually ran the model.
                firedLoad.append(metric.loadMilliseconds); firedEmbedding.append(metric.embeddingMilliseconds)
                firedTotal.append(metric.totalMilliseconds)
                row["loadMilliseconds"] = metric.loadMilliseconds; row["embeddingMilliseconds"] = metric.embeddingMilliseconds
                row["totalMilliseconds"] = metric.totalMilliseconds
            }
            rows.append(row)
        }
        let abstained = rows.filter { $0["bm25Abstained"] as? Bool == true }
        let noMatchTop = abstained.filter { $0["kind"] as? String == "noMatch" }.compactMap { $0["topSemanticCosine"] as? Double }
        let summary: [String: Any] = [
            "cases": cases.count, "semanticFallbackCosine": cutoff,
            "bm25Abstained": abstained.count, "fallbackOutcomes": outcomes,
            "fallbackRan": (outcomes["served"] ?? 0) + (outcomes["nothingAboveCutoff"] ?? 0),
            "fallbackServed": outcomes["served"] ?? 0,
            "rescuedExpectedShown": rescued, "rescuedExpectedFirst": rescuedFirst,
            "wrongFallbackResults": wrongByKind.values.reduce(0, +), "wrongFallbackResultsByKind": wrongByKind,
            "maximumFallbackConfidence": maximumFallbackConfidence,
            "noMatchCasesThatGainedResults": noMatchGainedResults,
            "noMatchTopSemanticCosineMax": noMatchTop.max() ?? .nan,
            "expectedTop1BM25": rows.filter { $0["expectedTop1BM25"] as? Bool == true }.count,
            "expectedTop1WithFallback": rows.filter { $0["expectedTop1"] as? Bool == true }.count,
            "firedLoadMillisecondsMedian": Self.percentile(firedLoad.sorted(), 0.5),
            "firedEmbeddingMillisecondsMedian": Self.percentile(firedEmbedding.sorted(), 0.5),
            "firedTotalMillisecondsMedian": Self.percentile(firedTotal.sorted(), 0.5),
            "firedTotalMillisecondsMax": firedTotal.max() ?? .nan,
        ]
        print("SEMANTIC-FALLBACK " + String(decoding: try JSONSerialization.data(withJSONObject: Self.finite(summary), options: [.sortedKeys]), as: UTF8.self))
        if let path = environment["DIVEID_SEMANTIC_REPORT"] {
            var report = Self.finite(summary)
            report["schemaVersion"] = 4
            report["design"] = "semantic fallback only when BM25 ranks nothing"
            report["fixtures"] = ["V05Development.v2", "CaribbeanIdentificationBenchmark (development split)"]
            report["pack"] = "\(pack.metadata.id.rawValue):\(pack.metadata.packVersion)"
            report["speciesCount"] = pack.profiles.count
            report["rows"] = rows.map(Self.finite)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
