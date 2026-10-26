import Foundation
import XCTest
@testable import DiveID

/// The search index store: one build per content, cancellation, background preparation,
/// and the persisted archive's parity, invalidation and corruption recovery.
final class SearchIndexStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchIndexStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func repository(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess = .experimentalDevelopment) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access)
    }

    /// A small slice of the Tropical Pacific pack, keyed like a repository-loaded pack.
    private func pack(count: Int = 60, key: String? = "test-content-1") async throws -> OfflineIdentificationPack {
        let full = try await repository().loadPack(id: .tropicalPacific)
        var metadata = full.metadata
        let profiles = Array(full.profiles.prefix(count))
        metadata.speciesCount = profiles.count
        return OfflineIdentificationPack(metadata: metadata, profiles: profiles, persistentContentKey: key)
    }

    private func archives() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "bm25" }
    }

    private let builder = SpeciesSearchDocumentBuilder()

    // MARK: Parity

    func testArchiveRoundTripIsIdenticalAndRetrievesIdentically() async throws {
        let pack = try await repository().loadPack(id: .tropicalPacific)
        let built = BM25Index(documents: pack.profiles.map { builder.document(from: $0, pack: pack.metadata) })
        let decoded = try XCTUnwrap(SearchIndexArchive.decode(SearchIndexArchive.encode(built, header: "h"), header: "h"))
        XCTAssertEqual(decoded, built)
        XCTAssertEqual(decoded.averageLength.bitPattern, built.averageLength.bitPattern)
        let queries = ["blue fish on a reef", "Twospot surgeonfish", "a leaflike bottom fish with a tall dorsal fin",
                       "yellow and blue striped fish", "maroon anemonefish with white bars", "large ray over sand"]
        for query in queries {
            let a = try await BM25SpeciesCandidateRetriever().retrieve(query: query, index: built, limit: 50)
            let b = try await BM25SpeciesCandidateRetriever().retrieve(query: query, index: decoded, limit: 50)
            XCTAssertEqual(a, b, query)
        }
        XCTAssertNil(SearchIndexArchive.decode(SearchIndexArchive.encode(built, header: "h"), header: "other header"))
    }

    func testRepositoryPacksCarryAStableContentKey() async throws {
        // Mediterranean is the smallest region drawn from Global: its key names Global's
        // resource, the region and its membership.
        let first = try await repository().loadPack(id: .mediterranean)
        let second = try await repository().loadPack(id: .mediterranean)
        let key = try XCTUnwrap(first.persistentContentKey)
        XCTAssertTrue(key.hasPrefix("development-"))
        XCTAssertTrue(key.contains("-mediterranean-"))
        XCTAssertEqual(key, second.persistentContentKey, "same resource, same key in a new repository")
        let global = try await repository().loadPack(id: .global)
        XCTAssertTrue(key.hasPrefix(try XCTUnwrap(global.persistentContentKey)))
        let release = try await repository(.publication).loadPack(id: .mediterranean)
        XCTAssertEqual(release.persistentContentKey, "publication-" + key.dropFirst("development-".count))
        XCTAssertNil(OfflineIdentificationPack(metadata: first.metadata, profiles: first.profiles).persistentContentKey)
    }

    // MARK: Persistence

    func testALaterLaunchLoadsTheArchiveInsteadOfRebuilding() async throws {
        let pack = try await pack()
        let first = SearchIndexStore(directory: directory)
        let built = try await first.index(pack: pack, builder: builder)
        await first.waitForPendingWrites()
        let firstStatistics = await first.statistics
        XCTAssertEqual(firstStatistics, .init(builds: 1, archiveLoads: 0, archiveRejections: 0, archiveWrites: 1))
        XCTAssertEqual(archives().count, 1)

        let relaunched = SearchIndexStore(directory: directory)
        let loaded = try await relaunched.index(pack: pack, builder: builder)
        let statistics = await relaunched.statistics
        XCTAssertEqual(statistics, .init(builds: 0, archiveLoads: 1, archiveRejections: 0, archiveWrites: 0))
        XCTAssertEqual(loaded, built)
    }

    func testChangedContentOrAppBuildInvalidatesTheArchive() async throws {
        let original = try await pack(key: "content-A")
        let store = SearchIndexStore(directory: directory, appBuild: "1.0(1)")
        _ = try await store.index(pack: original, builder: builder)
        await store.waitForPendingWrites()
        let before = archives()
        XCTAssertEqual(before.count, 1)

        // New catalogue content: rebuilt, and the stale archive is replaced.
        let changed = try await pack(key: "content-B")
        let next = SearchIndexStore(directory: directory, appBuild: "1.0(1)")
        _ = try await next.index(pack: changed, builder: builder)
        await next.waitForPendingWrites()
        let afterContent = await next.statistics
        XCTAssertEqual(afterContent.builds, 1)
        XCTAssertEqual(afterContent.archiveLoads, 0)
        XCTAssertEqual(archives().count, 1)
        XCTAssertNotEqual(archives(), before)

        // A new app build: rebuilt as well.
        let updated = SearchIndexStore(directory: directory, appBuild: "1.1(2)")
        _ = try await updated.index(pack: changed, builder: builder)
        let afterUpdate = await updated.statistics
        XCTAssertEqual(afterUpdate.builds, 1)
        XCTAssertEqual(afterUpdate.archiveLoads, 0)
    }

    func testAMissingArchiveIsRebuilt() async throws {
        let pack = try await pack()
        let store = SearchIndexStore(directory: directory)
        let built = try await store.index(pack: pack, builder: builder)
        await store.waitForPendingWrites()
        for url in archives() { try FileManager.default.removeItem(at: url) }
        let relaunched = SearchIndexStore(directory: directory)
        let rebuilt = try await relaunched.index(pack: pack, builder: builder)
        let statistics = await relaunched.statistics
        XCTAssertEqual(statistics.builds, 1)
        XCTAssertEqual(statistics.archiveRejections, 0)
        XCTAssertEqual(rebuilt, built)
    }

    func testCorruptOrTruncatedArchivesAreRejectedAndRebuilt() async throws {
        let pack = try await pack()
        let store = SearchIndexStore(directory: directory)
        let built = try await store.index(pack: pack, builder: builder)
        await store.waitForPendingWrites()
        let url = try XCTUnwrap(archives().first)
        let good = try Data(contentsOf: url)
        var flipped = good
        flipped[good.count / 2] ^= 0xFF
        for damaged in [flipped, good.prefix(good.count / 3), Data(), Data("not an index".utf8)] {
            try damaged.write(to: url)
            let relaunched = SearchIndexStore(directory: directory)
            let index = try await relaunched.index(pack: pack, builder: builder)
            await relaunched.waitForPendingWrites()
            let statistics = await relaunched.statistics
            XCTAssertEqual(statistics, .init(builds: 1, archiveLoads: 0, archiveRejections: 1, archiveWrites: 1))
            XCTAssertEqual(index, built)
            XCTAssertEqual(try Data(contentsOf: url), good, "the rebuilt archive replaces the damaged one")
        }
    }

    func testAnIntactArchiveWithDifferentEntriesOrRecordsIsRejected() async throws {
        let pack = try await pack()
        let store = SearchIndexStore(directory: directory)
        let built = try await store.index(pack: pack, builder: builder)
        await store.waitForPendingWrites()
        let url = try XCTUnwrap(archives().first)
        let header = try XCTUnwrap(SearchIndexArchive.header(of: Data(contentsOf: url)))
        let altered = BM25Index(entries: built.entries.map { entry in
            var counts = entry.termFrequencies
            counts["fish", default: 0] += 1
            return .init(speciesID: entry.speciesID, termFrequencies: counts, length: entry.length + 1, normalizedNames: entry.normalizedNames)
        })
        let missingRecord = BM25Index(entries: Array(built.entries.dropLast()))
        for replacement in [altered, missingRecord] {
            // Correct header and checksum: only the content checks can reject it.
            try SearchIndexArchive.encode(replacement, header: header).write(to: url)
            let relaunched = SearchIndexStore(directory: directory)
            let index = try await relaunched.index(pack: pack, builder: builder)
            await relaunched.waitForPendingWrites()
            let statistics = await relaunched.statistics
            XCTAssertEqual(statistics.archiveRejections, 1)
            XCTAssertEqual(statistics.builds, 1)
            XCTAssertEqual(index, built)
        }
    }

    func testPacksWithoutAContentKeyOrWithoutADirectoryAreNeverWritten() async throws {
        let unkeyed = try await pack(key: nil)
        let store = SearchIndexStore(directory: directory)
        _ = try await store.index(pack: unkeyed, builder: builder)
        await store.waitForPendingWrites()
        XCTAssertTrue(archives().isEmpty)
        let memoryOnly = SearchIndexStore(directory: nil)
        _ = try await memoryOnly.index(pack: try await pack(), builder: builder)
        await memoryOnly.waitForPendingWrites()
        let statistics = await memoryOnly.statistics
        XCTAssertEqual(statistics.archiveWrites, 0)
        XCTAssertTrue(archives().isEmpty)
    }

    // MARK: Concurrency

    func testConcurrentRequestsShareOneBuild() async throws {
        let pack = try await pack()
        let store = SearchIndexStore(directory: nil)
        let builder = SpeciesSearchDocumentBuilder()
        let indexes = try await withThrowingTaskGroup(of: BM25Index.self) { group in
            for _ in 0..<16 { group.addTask { try await store.index(pack: pack, builder: builder) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(indexes.count, 16)
        XCTAssertTrue(indexes.allSatisfy { $0 == indexes[0] })
        let statistics = await store.statistics
        XCTAssertEqual(statistics.builds, 1)
    }

    /// Builds slowly, so a request can be cancelled while the build is running.
    private struct SlowBuilder: SpeciesSearchDocumentBuilding {
        func document(from profile: LocalSpeciesProfile, pack: OfflineIdentificationPackMetadata) -> SpeciesSearchDocument {
            Thread.sleep(forTimeInterval: 0.01)
            return SpeciesSearchDocumentBuilder().document(from: profile, pack: pack)
        }
    }

    func testACancelledRequestReturnsAtOnceAndTheBuildIsReused() async throws {
        let pack = try await pack(count: 60) // about 0.6 s to build
        let store = SearchIndexStore(directory: nil)
        let slow = SlowBuilder()
        let request = Task { try await store.index(pack: pack, builder: slow) }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = ContinuousClock.now
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("a cancelled request must not wait for the build")
        } catch is CancellationError {
            XCTAssertLessThan(cancelledAt.duration(to: .now), .milliseconds(300))
        }
        let index = try await store.index(pack: pack, builder: slow)
        XCTAssertEqual(index.entries.count, pack.profiles.count)
        let statistics = await store.statistics
        XCTAssertEqual(statistics.builds, 1, "the cancelled request's build was reused")
        // An already-cancelled caller never starts waiting.
        let precancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.index(pack: pack, builder: slow)
        }
        await XCTAssertThrowsErrorAsync(try await precancelled.value)
    }

    func testPreparationRunsInTheBackgroundAndTheSearchReusesIt() async throws {
        let store = SearchIndexStore(directory: directory)
        let catalog = repository()
        let started = ContinuousClock.now
        SearchIndexPreparation.start(packID: .caribbean, catalog: catalog, store: store)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(50), "starting never waits for the build")
        // Preparation alone builds the index, without any search asking for it.
        for _ in 0..<500 {
            if await store.statistics.builds == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let prepared = await store.statistics
        XCTAssertEqual(prepared.builds, 1)
        let pack = try await catalog.loadPack(id: .caribbean)
        let index = try await store.index(pack: pack, builder: builder)
        XCTAssertEqual(index.entries.count, pack.profiles.count)
        await store.waitForPendingWrites()
        let statistics = await store.statistics
        XCTAssertEqual(statistics, .init(builds: 1, archiveLoads: 0, archiveRejections: 0, archiveWrites: 1), "the search reused the prepared index")
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch {}
}
