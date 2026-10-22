import Foundation
import XCTest
@testable import DiveID

/// Host-side proxies for the V05 performance method (Docs/V05CandidateValidation.md):
/// catalogue load, search-document build, query latency (median and nearest-rank p95)
/// and resident memory, per pack. Not the iPhone search-to-visible measurement. Runs
/// only when DIVEID_PERF_REPORT names an output file; use `swift test -c release`.
final class GlobalPackPerformanceTests: XCTestCase {
    private struct Case: Decodable { let description: String }
    private struct Fixture: Decodable { let cases: [Case] }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private func time<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
        let start = ContinuousClock.now
        let value = try await body()
        return (value, milliseconds(start.duration(to: .now)))
    }

    /// Nearest-rank percentile, as the method specifies.
    private func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[max(0, Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1)]
    }

    /// VmRSS / VmHWM in MiB from /proc/self/status (Linux only; nil elsewhere).
    private func memory() -> [String: Double] {
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return [:] }
        var values: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "\t" })
            if parts.count >= 2, ["VmRSS", "VmHWM"].contains(String(parts[0])), let kb = Double(parts[1]) { values[String(parts[0])] = kb / 1024 }
        }
        return values
    }

    private func repository(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access)
    }

    func testCatalogueAndSearchCostsPerPack() async throws {
        guard let output = ProcessInfo.processInfo.environment["DIVEID_PERF_REPORT"] else {
            throw XCTSkip("Set DIVEID_PERF_REPORT to measure; run with swift test -c release.")
        }
        let queries = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: TestResources.fixture(named: "V05Development.v2"))).cases.map(\.description)
        let repetitions = Int(ProcessInfo.processInfo.environment["DIVEID_PERF_REPETITIONS"] ?? "") ?? 3
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        var packs: [[String: Any]] = []
        let processBaseline = memory()
        // The 250 records of Global batch 1: the size of the approved Release subset (built
        // in memory from development content; Release currently exposes no Global record).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let batchDirectory = root.appendingPathComponent("Data/CatalogReview/GlobalBatches/batch-01")
        let batchManifest = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: batchDirectory, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("manifest-g1-") })
        let batchIDs = Set(try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(contentsOf: batchManifest)) as? [String: Any])?["records"] as? [[String: Any]])
            .compactMap { ($0["speciesID"] as? String).flatMap(UUID.init(uuidString:)) })
        for (label, id, subset) in [("caribbean", OfflineIdentificationPackID.caribbean, false), ("tropical-pacific", .tropicalPacific, false),
                                    ("global", .global, false), ("global-batch-01-subset", .global, true)] {
            let before = memory()
            var loads: [Double] = [], pack: OfflineIdentificationPack!
            for _ in 0..<5 { let (value, ms) = try await time { try await repository(.experimentalDevelopment).loadPack(id: id) }; pack = value; loads.append(ms) }
            if subset {
                let profiles = pack.profiles.filter { batchIDs.contains($0.id) }
                var metadata = pack.metadata
                metadata.speciesCount = profiles.count
                pack = OfflineIdentificationPack(metadata: metadata, profiles: profiles)
            }
            let afterLoad = memory()
            let builder = SpeciesSearchDocumentBuilder()
            var builds: [Double] = [], documents: [SpeciesSearchDocument] = []
            for _ in 0..<3 { let (value, ms) = await time { pack.profiles.map { builder.document(from: $0, pack: pack.metadata) } }; documents = value; builds.append(ms) }
            // Content fingerprint: computed once when a pack is built, not per query.
            let (_, fingerprintMs) = await time { OfflineIdentificationPack(metadata: pack.metadata, profiles: pack.profiles).contentFingerprint }
            var indexBuilds: [Double] = [], index: BM25Index!
            for _ in 0..<3 { let (value, ms) = await time { BM25Index(documents: documents) }; index = value; indexBuilds.append(ms) }
            let retriever = BM25SpeciesCandidateRetriever()
            var retrieval: [Double] = []
            for query in queries { let (_, ms) = try await time { try await retriever.retrieve(query: query, index: index, limit: 50) }; retrieval.append(ms) }
            let engine = HybridDescriptionSearchEngine()
            // First query on this content: builds the cached documents and BM25 index.
            let (_, coldMs) = try await time { try await engine.search(description: queries[0], pack: pack) }
            var latencies: [Double] = []
            for _ in 0..<repetitions {
                for query in queries { let (_, ms) = try await time { try await engine.search(description: query, pack: pack) }; latencies.append(ms) }
            }
            let afterQueries = memory()
            let row: [String: Any] = [
                "pack": label, "records": pack.profiles.count,
                "loadMs": ["median": percentile(loads, 50), "p95": percentile(loads, 95), "samples": loads.count],
                "documentBuildMs": ["median": percentile(builds, 50), "samples": builds.count],
                "contentFingerprintMs": fingerprintMs,
                "indexBuildMs": ["median": percentile(indexBuilds, 50), "samples": indexBuilds.count],
                "bm25IndexedRetrievalMs": ["median": percentile(retrieval, 50), "p95": percentile(retrieval, 95), "samples": retrieval.count],
                "firstQueryMs": coldMs,
                "queryMs": ["median": percentile(latencies, 50), "p95": percentile(latencies, 95), "max": latencies.max() ?? 0, "samples": latencies.count, "failures": 0],
                "memoryMiB": ["metric": "VmRSS (resident set) and VmHWM (peak resident) from /proc/self/status", "beforeLoad": before, "afterLoad": afterLoad, "afterQueries": afterQueries]
            ]
            print("GLOBAL_PERF \(configuration) \(label) n=\(pack.profiles.count) load=\(percentile(loads, 50))ms docs=\(percentile(builds, 50))ms index=\(percentile(indexBuilds, 50))ms bm25=\(percentile(retrieval, 50))ms first=\(coldMs)ms query median=\(percentile(latencies, 50))ms p95=\(percentile(latencies, 95))ms rss=\(afterQueries["VmRSS"] ?? -1)MiB")
            packs.append(row)
        }
        // Listing reads manifests only; each sample uses a fresh repository (nothing cached).
        var listings: [Double] = [], developmentListings: [Double] = []
        for _ in 0..<5 { let (_, ms) = try await time { try await repository(.publication).availablePacks() }; listings.append(ms) }
        for _ in 0..<5 { let (_, ms) = try await time { try await repository(.experimentalDevelopment).availablePacks() }; developmentListings.append(ms) }
        let report: [String: Any] = [
            "schemaVersion": 1, "configuration": configuration, "kind": "host measurement (Linux container); not an iPhone search-to-visible measurement",
            "host": ProcessInfo.processInfo.operatingSystemVersionString, "processors": ProcessInfo.processInfo.activeProcessorCount,
            "queries": queries.count, "repetitions": repetitions, "processMemoryAtStartMiB": processBaseline,
            "publicationAvailablePacksMs": ["median": percentile(listings, 50), "p95": percentile(listings, 95), "samples": listings.count],
            "developmentAvailablePacksMs": ["median": percentile(developmentListings, 50), "p95": percentile(developmentListings, 95), "samples": developmentListings.count],
            "packs": packs
        ]
        print("GLOBAL_PERF \(configuration) availablePacks publication median=\(percentile(listings, 50))ms development median=\(percentile(developmentListings, 50))ms")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}
