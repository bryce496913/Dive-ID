import Foundation
import XCTest
@testable import DiveID

/// First-use instrumentation (signposts, the diagnostics row's data and the stored-index
/// actions) exists in Debug and Internal and never in Release. The binary check runs in
/// SwiftPM on macOS, where the app module is linked into the test bundle; CI checks the
/// built Xcode apps with Tools/CI/check_internal_instrumentation.py.
@MainActor
final class InternalInstrumentationTests: XCTestCase {
    /// Strings only the instrumentation contains, stored reversed so this file's own
    /// literals can never match them.
    private static let reversedMarkers = [
        "ecnamrofrep.DIeviD.noremacecyrb.moc", // signpost subsystem
        "erots dilavni retfa tliuber",         // index source shown in the row
        "erots morf dedaol"
    ]
    private static var markers: [String] { reversedMarkers.map { String($0.reversed()) } }

    /// Darwin only: on Linux the SwiftPM test runner does not carry these strings even in
    /// Debug (found on CI), so a scan there could not tell Release from Debug and would
    /// prove nothing. Linux still runs every behaviour test; the Release absence proof is
    /// this test on macOS and the CI check of the built Release app.
    func testReleaseBinariesContainNoInstrumentation() throws {
#if SWIFT_PACKAGE && canImport(Darwin)
        let binary = try XCTUnwrap(Bundle(for: InternalInstrumentationTests.self).executableURL)
        let data = try Data(contentsOf: binary)
        let foundInOrder = Self.markers.filter { data.range(of: Data($0.utf8)) != nil }
#if DEBUG || DIVEID_INTERNAL
        XCTAssertEqual(foundInOrder, Self.markers, "the check finds the instrumentation where it is compiled in; scanned \(binary.path)")
#else
        XCTAssertEqual(foundInOrder, [], "Release must not contain instrumentation; scanned \(binary.path)")
        XCTAssertEqual(BuildChannel.current, .release)
#endif
#elseif SWIFT_PACKAGE
        throw XCTSkip("Linux test binaries cannot show the instrumentation strings; macOS SwiftPM and the Xcode app check prove Release excludes them")
#else
        throw XCTSkip("Xcode app binaries are checked by Tools/CI/check_internal_instrumentation.py")
#endif
    }

#if DEBUG || DIVEID_INTERNAL
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("InternalInstrumentationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private struct OnePackCatalog: MarineSpeciesCatalogRepository {
        let pack: OfflineIdentificationPack
        func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
        func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { pack }
    }

    private func pack() async throws -> OfflineIdentificationPack {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let full = try await repository.loadPack(id: .tropicalPacific)
        var metadata = full.metadata
        let profiles = Array(full.profiles.prefix(40))
        metadata.speciesCount = profiles.count
        return OfflineIdentificationPack(metadata: metadata, profiles: profiles, persistentContentKey: "instrumentation-test")
    }

    private let builder = SpeciesSearchDocumentBuilder()

    /// Each launch is a new store on the same Caches directory, prepared the way the
    /// search screen prepares it; returns what the diagnostics row would show.
    private func launch(_ pack: OfflineIdentificationPack) async throws -> (InternalSearchDiagnostics.Readiness, SearchIndexStore) {
        let store = SearchIndexStore(directory: directory)
        let diagnostics = InternalSearchDiagnostics()
        await SearchIndexPreparation.start(packID: pack.metadata.id, catalog: OnePackCatalog(pack: pack), store: store,
                                           builder: builder, diagnostics: diagnostics).value
        await store.waitForPendingWrites()
        return (try XCTUnwrap(diagnostics.readiness[pack.metadata.id]), store)
    }

    func testTheRowReportsEachIndexSourceAndTheActionsDriveRecovery() async throws {
        let pack = try await pack()
        let (fresh, firstStore) = try await launch(pack)
        XCTAssertEqual(fresh.source, .built)
        XCTAssertGreaterThanOrEqual(fresh.timeToReady, fresh.index)
        XCTAssertGreaterThanOrEqual(fresh.timeToReady, fresh.catalogueLoad)
        let files = await firstStore.storedIndexURLs(for: pack.metadata.id)
        XCTAssertEqual(files.count, 1)

        let (later, laterStore) = try await launch(pack)
        XCTAssertEqual(later.source, .loadedFromStore)

        // Corrupt: same length and header, garbage in the middle; the next launch rebuilds.
        let url = try XCTUnwrap(files.first)
        let good = try Data(contentsOf: url)
        let corrupted = await laterStore.corruptStoredIndex(for: pack.metadata.id)
        XCTAssertEqual(corrupted, 1)
        let damaged = try Data(contentsOf: url)
        XCTAssertEqual(damaged.count, good.count)
        XCTAssertNotEqual(damaged, good)
        XCTAssertEqual(SearchIndexArchive.header(of: damaged), SearchIndexArchive.header(of: good))
        let (afterCorruption, recoveredStore) = try await launch(pack)
        XCTAssertEqual(afterCorruption.source, .rebuiltAfterInvalidStore)
        let recovered = try await recoveredStore.index(pack: pack, builder: builder)
        XCTAssertEqual(recovered, BM25Index(documents: pack.profiles.map { builder.document(from: $0, pack: pack.metadata) }))
        XCTAssertEqual(try Data(contentsOf: url), good)

        // Delete: the next launch builds from scratch.
        let deleted = await recoveredStore.deleteStoredIndex(for: pack.metadata.id)
        XCTAssertEqual(deleted, 1)
        let remaining = await recoveredStore.storedIndexURLs(for: pack.metadata.id)
        XCTAssertTrue(remaining.isEmpty)
        let (afterDeletion, _) = try await launch(pack)
        XCTAssertEqual(afterDeletion.source, .built)
    }

    func testTheActionsAreSafeWithoutAStoredIndex() async throws {
        let memoryOnly = SearchIndexStore(directory: nil)
        let deleted = await memoryOnly.deleteStoredIndex(for: .global)
        let corrupted = await memoryOnly.corruptStoredIndex(for: .global)
        XCTAssertEqual(deleted, 0)
        XCTAssertEqual(corrupted, 0)
    }

    func testReadinessKeepsTheFirstPreparationOfALaunch() {
        let diagnostics = InternalSearchDiagnostics()
        XCTAssertEqual(diagnostics.summary(for: .global), "Index: preparing… · Last query: none")
        diagnostics.recordReadiness(.init(source: .built, timeToReady: .milliseconds(4_930), catalogueLoad: .milliseconds(1_300), index: .milliseconds(3_630)), for: .global)
        diagnostics.recordReadiness(.init(source: .loadedFromStore, timeToReady: .milliseconds(2), catalogueLoad: .zero, index: .zero), for: .global)
        XCTAssertEqual(diagnostics.readiness[.global]?.source, .built)
        XCTAssertEqual(diagnostics.summary(for: .global), "Index: built · Ready: 4.93 s · Last query: none")
        XCTAssertEqual(diagnostics.breakdown(for: .global), "Catalogue 1.30 s + index 3.63 s")
        XCTAssertNil(diagnostics.readiness[.caribbean])
    }

    func testQueryTimingCoversSubmissionToFirstShownState() {
        let diagnostics = InternalSearchDiagnostics()
        diagnostics.queryFinished(.results)
        XCTAssertNil(diagnostics.lastQuery, "nothing pending: returning to shown results is not a query")
        diagnostics.querySubmitted(packID: .global)
        XCTAssertTrue(diagnostics.hasPendingQuery)
        diagnostics.queryFinished(.results)
        XCTAssertFalse(diagnostics.hasPendingQuery)
        XCTAssertEqual(diagnostics.lastQuery?.outcome, .results)
        let first = diagnostics.lastQuery
        diagnostics.queryFinished(.noResults)
        XCTAssertEqual(diagnostics.lastQuery, first, "only the first shown state ends a query")

        diagnostics.querySubmitted(packID: .global)
        diagnostics.querySubmitted(packID: .global)
        XCTAssertEqual(diagnostics.lastQuery?.outcome, .cancelled, "a new submission ends the pending one")
        diagnostics.queryFinished(.noResults)
        XCTAssertEqual(diagnostics.lastQuery?.outcome, .noResults)
        XCTAssertTrue(diagnostics.summary(for: .global).hasSuffix("(no results)"))
    }

    func testDurationsAreShownInMillisecondsOrSeconds() {
        XCTAssertEqual(InternalSearchDiagnostics.format(.milliseconds(54)), "54 ms")
        XCTAssertEqual(InternalSearchDiagnostics.format(.microseconds(999_400)), "999 ms")
        XCTAssertEqual(InternalSearchDiagnostics.format(.milliseconds(4_926)), "4.93 s")
    }

    func testEverySignpostIntervalCanBeginAndEnd() {
        for interval in SearchSignposts.Interval.allCases {
            SearchSignposts.end(SearchSignposts.begin(interval, "test"), "done")
        }
    }
#endif
}
