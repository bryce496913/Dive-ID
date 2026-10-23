#if DEBUG || DIVEID_INTERNAL
import Foundation
import Observation
#if canImport(os)
import os
#endif

// First-use performance instrumentation for Debug and the Internal configuration only.
// Nothing in this file, and none of its call sites, is compiled into Release: every
// use is inside `#if DEBUG || DIVEID_INTERNAL`. `InternalInstrumentationTests` checks the
// SwiftPM binaries and `Tools/CI/check_internal_instrumentation.py` checks the built apps.

/// Signpost intervals, shown in Instruments' Points of Interest track (subsystem
/// `com.brycecameron.DiveID.performance`). A no-op where `os` is unavailable (Linux).
enum SearchSignposts {
    enum Interval: Sendable, CaseIterable {
        case catalogueLoad, indexLoadFromStore, indexBuild, backgroundPreparation, queryToFirstResult
    }

    struct Token {
        let interval: Interval
#if canImport(os)
        fileprivate let state: OSSignpostIntervalState
#endif
    }

    static let subsystem = "com.brycecameron.DiveID.performance"

#if canImport(os)
    private static let signposter = OSSignposter(logHandle: OSLog(subsystem: subsystem, category: .pointsOfInterest))
#endif

    /// Begins an interval; `detail` (a pack ID, never query text) is shown with it.
    static func begin(_ interval: Interval, _ detail: String = "") -> Token {
#if canImport(os)
        let id = signposter.makeSignpostID()
        let state: OSSignpostIntervalState
        switch interval {
        case .catalogueLoad: state = signposter.beginInterval("Catalogue load", id: id, "\(detail, privacy: .public)")
        case .indexLoadFromStore: state = signposter.beginInterval("Index load from store", id: id, "\(detail, privacy: .public)")
        case .indexBuild: state = signposter.beginInterval("Index build", id: id, "\(detail, privacy: .public)")
        case .backgroundPreparation: state = signposter.beginInterval("Background preparation", id: id, "\(detail, privacy: .public)")
        case .queryToFirstResult: state = signposter.beginInterval("Query to first result", id: id, "\(detail, privacy: .public)")
        }
        return Token(interval: interval, state: state)
#else
        return Token(interval: interval)
#endif
    }

    /// Ends an interval; `outcome` (for example "loaded" or "cancelled") is shown with it.
    static func end(_ token: Token, _ outcome: String = "") {
#if canImport(os)
        switch token.interval {
        case .catalogueLoad: signposter.endInterval("Catalogue load", token.state, "\(outcome, privacy: .public)")
        case .indexLoadFromStore: signposter.endInterval("Index load from store", token.state, "\(outcome, privacy: .public)")
        case .indexBuild: signposter.endInterval("Index build", token.state, "\(outcome, privacy: .public)")
        case .backgroundPreparation: signposter.endInterval("Background preparation", token.state, "\(outcome, privacy: .public)")
        case .queryToFirstResult: signposter.endInterval("Query to first result", token.state, "\(outcome, privacy: .public)")
        }
#endif
    }
}

/// Where the search index came from on this launch.
enum SearchIndexSource: String, Sendable, Equatable {
    case built = "built"
    case loadedFromStore = "loaded from store"
    case rebuiltAfterInvalidStore = "rebuilt after invalid store"
}

/// How one index request was satisfied, recorded by `SearchIndexStore`.
struct SearchIndexOutcome: Sendable, Equatable {
    let source: SearchIndexSource
    /// Loading or building the index, excluding the catalogue load.
    let duration: Duration
}

/// What the Internal diagnostics row shows: index source, time to ready and the last
/// query time. Readiness is kept per pack for the first preparation of each launch, so
/// reopening the search screen does not replace it with an in-memory hit.
@MainActor @Observable
final class InternalSearchDiagnostics {
    static let shared = InternalSearchDiagnostics()

    struct Readiness: Sendable, Equatable {
        let source: SearchIndexSource
        /// Background preparation start (the search screen opening) to index ready:
        /// catalogue load plus index load or build.
        let timeToReady: Duration
        let catalogueLoad: Duration
        let index: Duration
    }

    enum QueryOutcome: String, Sendable, Equatable {
        case results, noResults = "no results", failed, cancelled
    }

    struct QueryTiming: Sendable, Equatable {
        /// Find Matches tap to results (or the no-match or error state) on screen.
        let duration: Duration
        let outcome: QueryOutcome
    }

    private(set) var readiness: [OfflineIdentificationPackID: Readiness] = [:]
    private(set) var lastQuery: QueryTiming?
    @ObservationIgnored private var pendingQuery: (start: ContinuousClock.Instant, token: SearchSignposts.Token)?

    var hasPendingQuery: Bool { pendingQuery != nil }

    func recordReadiness(_ value: Readiness, for packID: OfflineIdentificationPackID) {
        if readiness[packID] == nil { readiness[packID] = value }
    }

    /// Find Matches was tapped. A query still pending is ended as cancelled.
    func querySubmitted(packID: OfflineIdentificationPackID) {
        if pendingQuery != nil { queryFinished(.cancelled) }
        pendingQuery = (ContinuousClock.now, SearchSignposts.begin(.queryToFirstResult, packID.rawValue))
    }

    /// The results screen shows its first state after a submission. No-op when nothing
    /// is pending, for example when returning to results that were already shown.
    func queryFinished(_ outcome: QueryOutcome) {
        guard let pending = pendingQuery else { return }
        pendingQuery = nil
        SearchSignposts.end(pending.token, outcome.rawValue)
        lastQuery = QueryTiming(duration: pending.start.duration(to: .now), outcome: outcome)
    }

    /// The one-line summary for a pack, for example
    /// "Index: loaded from store · Ready: 0.91 s · Last query: 62 ms".
    func summary(for packID: OfflineIdentificationPackID) -> String {
        let index = readiness[packID].map { "Index: \($0.source.rawValue) · Ready: \(Self.format($0.timeToReady))" } ?? "Index: preparing…"
        let query = lastQuery.map { "Last query: \(Self.format($0.duration))" + ($0.outcome == .results ? "" : " (\($0.outcome.rawValue))") } ?? "Last query: none"
        return index + " · " + query
    }

    /// The parts of readiness, for example "Catalogue 0.74 s + index 0.17 s".
    func breakdown(for packID: OfflineIdentificationPackID) -> String? {
        readiness[packID].map { "Catalogue \(Self.format($0.catalogueLoad)) + index \(Self.format($0.index))" }
    }

    nonisolated static func format(_ duration: Duration) -> String {
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return milliseconds < 1_000 ? "\(Int(milliseconds.rounded())) ms" : String(format: "%.2f s", milliseconds / 1_000)
    }
}

/// Internal testing actions on the stored index, so recovery can be tried on a device.
/// They change the Caches file only; the in-memory index stays until the next launch.
extension SearchIndexStore {
    /// Deletes this pack's stored indexes. Returns how many files were removed.
    func deleteStoredIndex(for packID: OfflineIdentificationPackID) async -> Int {
        await waitForPendingWrites()
        var removed = 0
        for url in storedIndexURLs(for: packID) where (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        return removed
    }

    /// Overwrites the middle half of each stored index with random bytes, keeping its
    /// length, header and trailing checksum, so only validation can catch it. Returns
    /// how many files were corrupted.
    func corruptStoredIndex(for packID: OfflineIdentificationPackID) async -> Int {
        await waitForPendingWrites()
        var corrupted = 0
        for url in storedIndexURLs(for: packID) {
            guard var bytes = try? Data(contentsOf: url), bytes.count >= 8 else { continue }
            var generator = SystemRandomNumberGenerator()
            for offset in (bytes.count / 4)..<(bytes.count * 3 / 4) { bytes[offset] = generator.next() }
            if (try? bytes.write(to: url)) != nil { corrupted += 1 }
        }
        return corrupted
    }
}

extension SearchIndexPreparation {
    /// `start`, plus a background-preparation interval and the readiness record for the
    /// diagnostics row. The returned task finishes when the index is ready (tests).
    @discardableResult
    static func start(packID: OfflineIdentificationPackID, catalog: any MarineSpeciesCatalogRepository,
                      store: SearchIndexStore = .shared, builder: any SpeciesSearchDocumentBuilding = SpeciesSearchDocumentBuilder(),
                      diagnostics: InternalSearchDiagnostics) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            let interval = SearchSignposts.begin(.backgroundPreparation, packID.rawValue)
            guard let pack = try? await catalog.loadPack(id: packID) else {
                SearchSignposts.end(interval, "catalogue failed")
                return
            }
            let loaded = ContinuousClock.now
            _ = await store.prepare(pack: pack, builder: builder).value
            let outcome = await store.indexOutcome(pack: pack, builder: builder)
            SearchSignposts.end(interval, outcome?.source.rawValue ?? "ready")
            guard let outcome else { return }
            await diagnostics.recordReadiness(.init(source: outcome.source, timeToReady: started.duration(to: .now),
                                                    catalogueLoad: started.duration(to: loaded), index: outcome.duration), for: packID)
        }
    }
}
#endif
