import Foundation
import XCTest
@testable import DiveID

@MainActor
final class IdentificationLifecycleTests: XCTestCase {
    private let catalog = LifecycleCatalog()
    private func request() -> IdentificationRequest {
        .init(source: .description("striped reef fish"))
    }
    private func match() -> IdentificationMatch {
        .init(id: MockSpecies.all[0].id, species: MockSpecies.all[0], score: 0.8, scoreKind: .relativeMatch)
    }
    private func assertMissing(_ id: UUID, in store: InMemoryIdentificationSessionStore) async {
        do { _ = try await store.request(for: id); XCTFail("Abandoned session was retained") }
        catch IdentificationSessionStoreError.sessionNotFound { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRouteAbandonmentCancelsServiceAndRejectsLateCompletion() async throws {
        let store = InMemoryIdentificationSessionStore()
        let router = AppRouter(sessionStore: store)
        let id = try await store.createSession(for: request())
        router.navigate(to: .identificationResults(sessionID: id))
        await router.waitForSessionUpdates()
        let service = ControlledLifecycleService()
        let model = router.resultsModel(sessionID: id, service: service, catalog: catalog)
        let loading = Task { await model.loadIfNeeded() }
        await service.waitForCalls(1)
        // Direct path mutation covers NavigationStack's interactive back binding too.
        router.path = []
        await service.waitForCancellation(0)
        await router.waitForSessionUpdates()
        await assertMissing(id, in: store)
        await service.finish(0, matches: [match()]) // Intentionally ignores cancellation.
        await loading.value
        guard case .idle = model.state else { return XCTFail("Late completion updated state") }
        await assertMissing(id, in: store)
    }

    func testImmediateRestartAndOldCleanupCannotCancelOrOverwriteNewOwner() async throws {
        let store = InMemoryIdentificationSessionStore()
        let id = try await store.createSession(for: request())
        let service = ControlledLifecycleService()
        let model = IdentificationResultsViewModel(sessionID: id, service: service, sessionStore: store, catalog: catalog)
        let first = Task { await model.loadIfNeeded() }
        await service.waitForCalls(1)
        model.cancel()
        let second = Task { await model.loadIfNeeded() }
        await service.waitForCalls(2)
        await service.fail(0)
        await first.value
        guard case .loading = model.state else { return XCTFail("Old failure replaced new loading state") }
        let cache = try await store.result(for: id)
        XCTAssertNil(cache)
        // If old cleanup cleared loadTask, this would fail to reach the second service call.
        model.cancel()
        await service.waitForCancellation(1)
        await service.finish(1, matches: [match()])
        await second.value
        let third = Task { await model.loadIfNeeded() }
        await service.waitForCalls(3)
        await service.finish(2, matches: [match()])
        await third.value
        guard case .loaded(let values) = model.state else { return XCTFail("Restart did not load") }
        XCTAssertEqual(values.count, 1)
        let savedResult = try await store.result(for: id)
        XCTAssertEqual(savedResult?.matches.count, 1)
    }

    func testLateSuccessCannotReplaceNewerCompletedResults() async throws {
        let store = InMemoryIdentificationSessionStore()
        let id = try await store.createSession(for: request())
        let service = ControlledLifecycleService()
        let model = IdentificationResultsViewModel(sessionID: id, service: service, sessionStore: store, catalog: catalog)
        let first = Task { await model.loadIfNeeded() }
        await service.waitForCalls(1)
        model.cancel()
        let second = Task { await model.loadIfNeeded() }
        await service.waitForCalls(2)
        await service.finish(1, matches: [])
        await second.value
        await service.finish(0, matches: [match()])
        await first.value
        guard case .empty = model.state else { return XCTFail("Obsolete success changed results") }
        let result = try await store.result(for: id)
        XCTAssertEqual(result?.matches.count, 0)
    }

    func testDetailsAndBackReuseResultsThenReleaseWithoutLosingSavedSighting() async throws {
        let store = InMemoryIdentificationSessionStore()
        let router = AppRouter(sessionStore: store)
        let id = try await store.createSession(for: request())
        router.navigate(to: .identificationResults(sessionID: id))
        await router.waitForSessionUpdates()
        let service = ControlledLifecycleService()
        let model = router.resultsModel(sessionID: id, service: service, catalog: catalog)
        let loading = Task { await model.loadIfNeeded() }
        await service.waitForCalls(1)
        await service.finish(0, matches: [match()])
        await loading.value
        guard case .loaded(let results) = model.state else { return XCTFail("Missing results") }
        let result = try XCTUnwrap(results.first)
        router.navigate(to: .speciesDetail(result.species, result))
        await router.waitForSessionUpdates()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("saved.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let savedRepository = try JSONSavedIdentificationRepository(fileURL: file)
        let saved = try await savedRepository.save(SavedIdentification(match: result))
        router.goBack()
        await router.waitForSessionUpdates()
        let returned = router.resultsModel(sessionID: id, service: service, catalog: catalog)
        XCTAssertTrue(returned === model)
        await returned.loadIfNeeded()
        let count = await service.callCount
        XCTAssertEqual(count, 1)
        let cache = try await store.result(for: id)
        XCTAssertEqual(cache?.matches.first?.species.id, result.species.id)
        router.goBack()
        await router.waitForSessionUpdates()
        await assertMissing(id, in: store)
        let reopened = try JSONSavedIdentificationRepository(fileURL: file)
        let sightings = try await reopened.fetchAll()
        XCTAssertEqual(sightings.first?.id, saved.id)
        router.navigate(to: .savedIdentification(saved))
        await router.waitForSessionUpdates()
        await assertMissing(id, in: store)
    }

    func testTemporaryViewTaskCancellationDoesNotAbandonNavigationOwnedSearch() async throws {
        let store = InMemoryIdentificationSessionStore()
        let router = AppRouter(sessionStore: store)
        let id = try await store.createSession(for: request())
        router.navigate(to: .identificationResults(sessionID: id))
        await router.waitForSessionUpdates()
        let service = ControlledLifecycleService()
        let model = router.resultsModel(sessionID: id, service: service, catalog: catalog)
        let viewTask = Task { await model.loadIfNeeded() }
        await service.waitForCalls(1)
        var detail = match()
        detail.sourceSessionID = id
        router.navigate(to: .speciesDetail(detail.species, detail))
        viewTask.cancel() // SwiftUI cancels .task when the results view disappears.
        await router.waitForSessionUpdates()
        await service.finish(0, matches: [detail])
        await viewTask.value
        guard case .loaded = model.state else { return XCTFail("Temporary disappearance abandoned results") }
        let cancellations = await service.cancellationCount
        XCTAssertEqual(cancellations, 0)
        router.goBack()
        await router.waitForSessionUpdates()
        XCTAssertTrue(router.resultsModel(sessionID: id, service: service, catalog: catalog) === model)
        router.path = []
        await router.waitForSessionUpdates()
        await assertMissing(id, in: store)
    }

    func testRepeatedCompletedFlowsReleaseSessions() async throws {
        let store = InMemoryIdentificationSessionStore(maximumSessions: 2)
        let router = AppRouter(sessionStore: store)
        for _ in 0..<30 {
            let id = try await store.createSession(for: request())
            router.navigate(to: .identificationResults(sessionID: id))
            await router.waitForSessionUpdates()
            let model = router.resultsModel(sessionID: id, service: MockMarineLifeIdentificationService(delay: .zero), catalog: catalog)
            await model.loadIfNeeded()
            guard case .loaded = model.state else { return XCTFail("Search failed") }
            router.goBack()
            await router.waitForSessionUpdates()
            await assertMissing(id, in: store)
        }
    }

    func testCancelledWriterCannotCommitToSessionStore() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = request()
        let id = try await store.createSession(for: request)
        let gate = ControlledLifecycleService()
        let writer = Task {
            _ = try await gate.identify(request: request, processedPhoto: nil)
            try await store.saveResult(.init(matches: [], completedAt: Date()), for: id)
        }
        await gate.waitForCalls(1)
        writer.cancel()
        await gate.finish(0, matches: [])
        do { try await writer.value; XCTFail("Cancelled write committed") }
        catch is CancellationError { }
        let result = try await store.result(for: id)
        XCTAssertNil(result)
    }

    func testPhotoDataReleasedWithFlowAndCacheEviction() async throws {
        let store = InMemoryIdentificationSessionStore(maximumSessions: 1)
        let photo = ProcessedPhoto(id: UUID(), previewData: Data([1]), uploadData: Data([2]),
                                   pixelWidth: 1, pixelHeight: 1, format: .jpeg)
        let id = try await store.createSession(for: .init(source: .processedPhoto(photo.reference)), photo: photo)
        let router = AppRouter(sessionStore: store)
        router.navigate(to: .identificationResults(sessionID: id))
        await router.waitForSessionUpdates()
        router.goBack()
        await router.waitForSessionUpdates()
        do { _ = try await store.photo(for: photo.reference); XCTFail("Photo retained after flow ended") }
        catch IdentificationSessionStoreError.photoNotFound { }
        _ = try await store.createSession(for: .init(source: .processedPhoto(photo.reference)), photo: photo)
        _ = try await store.createSession(for: request())
        do { _ = try await store.photo(for: photo.reference); XCTFail("Photo retained after eviction") }
        catch IdentificationSessionStoreError.photoNotFound { }
    }

    func testProductionServicePropagatesCatalogueCancellation() async throws {
        let service = LocalMarineLifeIdentificationService(catalogRepository: CancelledLifecycleCatalog())
        do { _ = try await service.identify(request: request(), processedPhoto: nil); XCTFail("Cancellation was swallowed") }
        catch is CancellationError { }
    }

    func testInactiveCacheIsBoundedAndActiveFlowsAreNotEvicted() async throws {
        let store = InMemoryIdentificationSessionStore(maximumSessions: 2)
        let active = try await store.createSession(for: request())
        await store.retainSessions([active])
        var previous: UUID?
        for _ in 0..<30 {
            let next = try await store.createSession(for: request())
            try await store.saveResult(.init(matches: [match()], completedAt: Date()), for: next)
            if let previous { await assertMissing(previous, in: store) }
            previous = next
            _ = try await store.request(for: active)
        }
        let last = try XCTUnwrap(previous)
        await store.retainSessions([active, last])
        do { _ = try await store.createSession(for: request()); XCTFail("Exceeded active-session bound") }
        catch IdentificationSessionStoreError.capacityReached { }
        _ = try await store.request(for: active)
        _ = try await store.request(for: last)
    }
}

private struct LifecycleCatalog: MarineSpeciesCatalogRepository {
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [] }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { throw LocalCatalogError.resourceMissing }
}

private actor ControlledLifecycleService: MarineLifeIdentificationService {
    private(set) var callCount = 0
    private var pending: [Int: CheckedContinuation<[IdentificationMatch], Error>] = [:]
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancelled: Set<Int> = []
    var cancellationCount: Int { cancelled.count }
    private var cancellationWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        let index = callCount
        callCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[index] = continuation
                let ready = startedWaiters.filter { $0.0 <= callCount }
                startedWaiters.removeAll { $0.0 <= callCount }
                ready.forEach { $0.1.resume() }
            }
        } onCancel: {
            Task { await self.recordCancellation(index) }
        }
    }
    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { startedWaiters.append((count, $0)) }
    }
    func waitForCancellation(_ index: Int) async {
        if cancelled.contains(index) { return }
        await withCheckedContinuation { cancellationWaiters[index] = $0 }
    }
    private func recordCancellation(_ index: Int) {
        cancelled.insert(index)
        cancellationWaiters.removeValue(forKey: index)?.resume()
    }
    func finish(_ index: Int, matches: [IdentificationMatch]) { pending.removeValue(forKey: index)?.resume(returning: matches) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: LocalIdentificationError.catalogUnavailable) }
}

private struct CancelledLifecycleCatalog: MarineSpeciesCatalogRepository {
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { throw CancellationError() }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { throw CancellationError() }
}
