import Foundation
import XCTest
@testable import DiveID

/// The first-use behaviours the Internal device test asks Bryce to confirm on an iPhone
/// (Docs/V05CandidateValidation.md, "Internal device performance test"), checked here
/// first: a search submitted before the index is ready, going back mid-search, a relaunch
/// after an interrupted build, a corrupt stored index and a stored index from an older
/// catalogue. Every configuration runs these, Release included.
@MainActor
final class FirstUsePerformanceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FirstUsePerformanceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Builds slowly (about 0.6 s for 60 records), so a search can arrive mid-build.
    private struct SlowBuilder: SpeciesSearchDocumentBuilding {
        func document(from profile: LocalSpeciesProfile, pack: OfflineIdentificationPackMetadata) -> SpeciesSearchDocument {
            Thread.sleep(forTimeInterval: 0.01)
            return SpeciesSearchDocumentBuilder().document(from: profile, pack: pack)
        }
    }

    /// Serves one pack, as the bundle repository would after decoding it.
    private struct OnePackCatalog: MarineSpeciesCatalogRepository {
        let pack: OfflineIdentificationPack
        func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
        func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { pack }
    }

    /// A slice of the Tropical Pacific pack, keyed like a repository-loaded pack.
    private func slicePack(count: Int = 60, key: String = "content-current", packVersion: Int? = nil) async throws -> OfflineIdentificationPack {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let full = try await repository.loadPack(id: .tropicalPacific)
        var metadata = full.metadata
        if let packVersion {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
            object["packVersion"] = packVersion
            metadata = try JSONDecoder().decode(OfflineIdentificationPackMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let profiles = Array(full.profiles.prefix(count))
        metadata.speciesCount = profiles.count
        return OfflineIdentificationPack(metadata: metadata, profiles: profiles, persistentContentKey: key)
    }

    private func query(_ pack: OfflineIdentificationPack) -> String { pack.profiles[10].commonName }

    private func reference(_ pack: OfflineIdentificationPack) -> BM25Index {
        let builder = SpeciesSearchDocumentBuilder()
        return BM25Index(documents: pack.profiles.map { builder.document(from: $0, pack: pack.metadata) })
    }

    private func service(_ pack: OfflineIdentificationPack, store: SearchIndexStore, builder: any SpeciesSearchDocumentBuilding = SlowBuilder()) -> LocalMarineLifeIdentificationService {
        LocalMarineLifeIdentificationService(catalogRepository: OnePackCatalog(pack: pack),
                                             searchEngine: HybridDescriptionSearchEngine(documentBuilder: builder, indexStore: store))
    }

    /// What a diver sees: the species in order, with their ranks and scores.
    private func shown(_ matches: [IdentificationMatch]) -> [String] {
        matches.map { "\($0.rank) \($0.species.id) \($0.score)" }
    }

    /// The results of the same search on an index that was already ready.
    private func expectedMatches(_ pack: OfflineIdentificationPack) async throws -> [IdentificationMatch] {
        let ready = service(pack, store: SearchIndexStore(directory: nil), builder: SpeciesSearchDocumentBuilder())
        let matches = try await ready.identify(request: request(pack), processedPhoto: nil)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertTrue(matches.contains { $0.species.id == pack.profiles[10].id }, "the name search finds its species")
        return matches
    }

    private func request(_ pack: OfflineIdentificationPack) -> IdentificationRequest {
        IdentificationRequest(source: .description(query(pack)), context: IdentificationContext(region: pack.metadata.id))
    }

    private func archives(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "bm25" }
    }

    private func isLoading<T>(_ state: LoadState<T>) -> Bool {
        switch state {
        case .idle, .loading: true // both show the progress view
        default: false
        }
    }

    // MARK: Fresh install, search submitted at once

    func testASearchSubmittedBeforeTheIndexIsReadyShowsProgressThenTheReadyResults() async throws {
        let pack = try await slicePack()
        let expected = try await expectedMatches(pack)
        let store = SearchIndexStore(directory: directory) // fresh install: nothing stored
        let slow = SlowBuilder()
        // The search screen opens and starts preparing; the diver submits at once.
        SearchIndexPreparation.start(packID: pack.metadata.id, catalog: OnePackCatalog(pack: pack), store: store, builder: slow)
        let sessions = InMemoryIdentificationSessionStore()
        let id = try await sessions.createSession(for: request(pack), photo: nil)
        let model = IdentificationResultsViewModel(sessionID: id, service: service(pack, store: store, builder: slow),
                                                   sessionStore: sessions, catalog: OnePackCatalog(pack: pack))
        let loading = Task { await model.loadIfNeeded() }
        var checks = 0
        while await store.statistics.builds == 0 && checks < 30 {
            XCTAssertTrue(isLoading(model.state), "while the index is not ready the screen shows progress, not \(model.state)")
            checks += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(checks, 5, "the search arrived while the index was still being built")
        await loading.value
        guard case .loaded(let matches) = model.state else { return XCTFail("expected results, got \(model.state)") }
        XCTAssertEqual(shown(matches), shown(expected), "the same results as a search on a ready index")
        await store.waitForPendingWrites()
        let statistics = await store.statistics
        XCTAssertEqual(statistics.builds, 1, "the search waited for the prepared build instead of starting another")
        XCTAssertEqual(statistics.archiveWrites, 1)
    }

    // MARK: Back mid-search

    func testGoingBackMidSearchCancelsCleanlyAndLeavesNoSession() async throws {
        let pack = try await slicePack()
        let expected = try await expectedMatches(pack)
        let store = SearchIndexStore(directory: directory)
        let searchService = service(pack, store: store)
        let sessions = InMemoryIdentificationSessionStore()
        let router = AppRouter(sessionStore: sessions)
        let first = try await sessions.createSession(for: request(pack), photo: nil)
        router.navigate(to: .identificationResults(sessionID: first))
        await router.waitForSessionUpdates()
        let model = router.resultsModel(sessionID: first, service: searchService, catalog: OnePackCatalog(pack: pack))
        let loading = Task { await model.loadIfNeeded() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(isLoading(model.state))
        let builds = await store.statistics.builds
        XCTAssertEqual(builds, 0, "still building when the diver goes back")

        let back = ContinuousClock.now
        router.goBack()
        await loading.value
        XCTAssertLessThan(back.duration(to: .now), .milliseconds(300), "going back does not wait for the build")
        guard case .idle = model.state else { return XCTFail("a cancelled search leaves no progress or results, got \(model.state)") }
        await router.waitForSessionUpdates()
        do { _ = try await sessions.request(for: first); XCTFail("the abandoned session was kept") }
        catch IdentificationSessionStoreError.sessionNotFound {}

        // The next search completes normally and reuses the build that carried on.
        let second = try await sessions.createSession(for: request(pack), photo: nil)
        router.navigate(to: .identificationResults(sessionID: second))
        await router.waitForSessionUpdates()
        let next = router.resultsModel(sessionID: second, service: searchService, catalog: OnePackCatalog(pack: pack))
        XCTAssertFalse(next === model)
        await next.loadIfNeeded()
        guard case .loaded(let matches) = next.state else { return XCTFail("expected results, got \(next.state)") }
        XCTAssertEqual(shown(matches), shown(expected))
        let statistics = await store.statistics
        XCTAssertEqual(statistics.builds, 1, "the cancelled search's build was reused")
        router.goBack()
        await router.waitForSessionUpdates()
        do { _ = try await sessions.request(for: second); XCTFail("a finished flow keeps no session") }
        catch IdentificationSessionStoreError.sessionNotFound {}
    }

    // MARK: Force-quit during the build, then relaunch

    func testARelaunchAfterAForceQuitDuringTheBuildRebuildsCorrectly() async throws {
        let pack = try await slicePack()
        let expected = reference(pack)
        let builder = SpeciesSearchDocumentBuilder()
        // What a completed launch would have stored, to derive what an interrupted one leaves.
        let scratch = directory.appendingPathComponent("complete", isDirectory: true)
        let complete = SearchIndexStore(directory: scratch)
        _ = try await complete.index(pack: pack, builder: builder)
        await complete.waitForPendingWrites()
        let stored = try XCTUnwrap(archives(in: scratch).first)
        let good = try Data(contentsOf: stored)

        // A force-quit can leave nothing (quit before the write), a partial file (if the
        // atomic write were ever lost), or another write's leftover for the same pack.
        let interruptions: [(String, (URL) throws -> Void)] = [
            ("quit before the write", { _ in }),
            ("partial archive", { try good.prefix(good.count / 2).write(to: $0.appendingPathComponent(stored.lastPathComponent)) }),
            ("leftover from another write", { try good.prefix(good.count / 3).write(to: $0.appendingPathComponent("\(pack.metadata.id.rawValue)-0000000000000000.bm25")) })
        ]
        for (name, interrupt) in interruptions {
            let launch = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: launch, withIntermediateDirectories: true)
            try interrupt(launch)
            let partial = FileManager.default.fileExists(atPath: launch.appendingPathComponent(stored.lastPathComponent).path)

            let relaunched = SearchIndexStore(directory: launch)
            let index = try await relaunched.index(pack: pack, builder: builder)
            await relaunched.waitForPendingWrites()
            let statistics = await relaunched.statistics
            XCTAssertEqual(statistics, .init(builds: 1, archiveLoads: 0, archiveRejections: partial ? 1 : 0, archiveWrites: 1), name)
            XCTAssertEqual(index, expected, name)
            XCTAssertEqual(archives(in: launch).map(\.lastPathComponent), [stored.lastPathComponent], "\(name): one intact archive remains")
            XCTAssertEqual(try Data(contentsOf: launch.appendingPathComponent(stored.lastPathComponent)), good, name)

            // The launch after that loads what the recovery wrote.
            let later = SearchIndexStore(directory: launch)
            let loaded = try await later.index(pack: pack, builder: builder)
            let laterStatistics = await later.statistics
            XCTAssertEqual(laterStatistics, .init(builds: 0, archiveLoads: 1, archiveRejections: 0, archiveWrites: 0), name)
            XCTAssertEqual(loaded, expected, name)
        }
    }

    // MARK: Corrupt stored index

    func testACorruptStoredIndexIsDetectedDiscardedAndRebuiltNeverUsed() async throws {
        let pack = try await slicePack()
        let expected = reference(pack)
        let builder = SpeciesSearchDocumentBuilder()
        let first = SearchIndexStore(directory: directory)
        _ = try await first.index(pack: pack, builder: builder)
        await first.waitForPendingWrites()
        let url = try XCTUnwrap(archives(in: directory).first)
        let good = try Data(contentsOf: url)

        // Garbage over the middle half, keeping the length, header and trailing checksum:
        // what the Internal "Corrupt stored index" action writes.
        var garbage = good
        var generator = SystemRandomNumberGenerator()
        for offset in (good.count / 4)..<(good.count * 3 / 4) { garbage[offset] = generator.next() }
        XCTAssertNotEqual(garbage, good)
        XCTAssertEqual(SearchIndexArchive.header(of: garbage), SearchIndexArchive.header(of: good))
        try garbage.write(to: url)

        let relaunched = SearchIndexStore(directory: directory)
        let index = try await relaunched.index(pack: pack, builder: builder)
        await relaunched.waitForPendingWrites()
        let statistics = await relaunched.statistics
        XCTAssertEqual(statistics, .init(builds: 1, archiveLoads: 0, archiveRejections: 1, archiveWrites: 1))
        XCTAssertEqual(index, expected, "the rebuilt index, not the corrupt one, is used")
        XCTAssertEqual(try Data(contentsOf: url), good, "the corrupt file was replaced")
        let retrieved = try await BM25SpeciesCandidateRetriever().retrieve(query: query(pack), index: index, limit: 50)
        let reference = try await BM25SpeciesCandidateRetriever().retrieve(query: query(pack), index: expected, limit: 50)
        XCTAssertEqual(retrieved, reference)
    }

    // MARK: Older catalogue content

    func testAStoredIndexFromAnOlderCatalogueContentVersionIsNeverUsed() async throws {
        let current = try await slicePack(key: "content-v3")
        let older = try await slicePack(count: 59, key: "content-v2", packVersion: current.metadata.packVersion - 1)
        let builder = SpeciesSearchDocumentBuilder()
        let before = SearchIndexStore(directory: directory)
        _ = try await before.index(pack: older, builder: builder)
        await before.waitForPendingWrites()
        let olderArchive = try XCTUnwrap(archives(in: directory).first)
        let olderBytes = try Data(contentsOf: olderArchive)

        // The app now ships the newer catalogue.
        let updated = SearchIndexStore(directory: directory)
        let index = try await updated.index(pack: current, builder: builder)
        await updated.waitForPendingWrites()
        let statistics = await updated.statistics
        XCTAssertEqual(statistics.archiveLoads, 0)
        XCTAssertEqual(statistics.builds, 1)
        XCTAssertEqual(index, reference(current))
        let remaining = archives(in: directory)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNotEqual(remaining.first?.lastPathComponent, olderArchive.lastPathComponent, "the older archive is removed")

        // Even under the current file name, the older archive's header rejects it.
        let currentArchive = try XCTUnwrap(remaining.first)
        try olderBytes.write(to: currentArchive)
        let relaunched = SearchIndexStore(directory: directory)
        let rebuilt = try await relaunched.index(pack: current, builder: builder)
        let relaunchStatistics = await relaunched.statistics
        XCTAssertEqual(relaunchStatistics.archiveLoads, 0)
        XCTAssertEqual(relaunchStatistics.archiveRejections, 1)
        XCTAssertEqual(rebuilt, reference(current))

        // Same records and content key but an older pack version: also never used.
        await relaunched.waitForPendingWrites()
        let olderVersion = try await slicePack(key: "content-v3", packVersion: current.metadata.packVersion - 1)
        let other = SearchIndexStore(directory: directory)
        _ = try await other.index(pack: olderVersion, builder: builder)
        let otherStatistics = await other.statistics
        XCTAssertEqual(otherStatistics.archiveLoads, 0)
        XCTAssertEqual(otherStatistics.builds, 1)
    }
}
