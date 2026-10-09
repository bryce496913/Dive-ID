import Foundation

enum IdentificationSessionStoreError: Error { case sessionNotFound, photoNotFound, duplicateSession, capacityReached }

protocol IdentificationSessionStore: Sendable {
    func createSession(for request: IdentificationRequest, photo: ProcessedPhoto?) async throws -> UUID
    func request(for sessionID: UUID) async throws -> IdentificationRequest
    func photo(for reference: ProcessedPhotoReference) async throws -> ProcessedPhoto
    func saveResult(_ result: IdentificationSessionResult, for sessionID: UUID) async throws
    func result(for sessionID: UUID) async throws -> IdentificationSessionResult?
    func removeSession(_ sessionID: UUID) async
    func retainSessions(_ sessionIDs: Set<UUID>) async
}

actor InMemoryIdentificationSessionStore: IdentificationSessionStore {
    private struct Session {
        let request: IdentificationRequest
        var result: IdentificationSessionResult?
    }

    private var sessions: [UUID: Session] = [:]
    private var photos: [UUID: ProcessedPhoto] = [:]
    private var accessOrder: [UUID] = []
    private var retained: Set<UUID> = []
    private let maximumSessions: Int

    // Hard count bound includes active flows, cached results and pending sessions.
    // Never evict a navigation-owned session; refuse admission if all slots are active.
    init(maximumSessions: Int = 16) {
        precondition(maximumSessions > 0)
        self.maximumSessions = maximumSessions
    }

    func retainSessions(_ sessionIDs: Set<UUID>) {
        retained = sessionIDs.intersection(Set(sessions.keys))
    }

    private func touch(_ id: UUID) {
        accessOrder.removeAll { $0 == id }
        accessOrder.append(id)
    }

    func createSession(for request: IdentificationRequest, photo: ProcessedPhoto? = nil) throws -> UUID {
        try Task.checkCancellation()
        guard sessions[request.id] == nil else { throw IdentificationSessionStoreError.duplicateSession }
        if sessions.count >= maximumSessions {
            guard let oldest = accessOrder.first(where: { !retained.contains($0) }) else {
                throw IdentificationSessionStoreError.capacityReached
            }
            removeSession(oldest)
        }
        if case .processedPhoto(let reference) = request.source,
           let photo, photo.id == reference.id { photos[photo.id] = photo }
        sessions[request.id] = Session(request: request)
        touch(request.id)
        return request.id
    }

    func request(for sessionID: UUID) throws -> IdentificationRequest {
        try Task.checkCancellation()
        guard let session = sessions[sessionID] else { throw IdentificationSessionStoreError.sessionNotFound }
        touch(sessionID)
        return session.request
    }

    func photo(for reference: ProcessedPhotoReference) throws -> ProcessedPhoto {
        try Task.checkCancellation()
        guard let photo = photos[reference.id] else { throw IdentificationSessionStoreError.photoNotFound }
        return photo
    }

    func saveResult(_ result: IdentificationSessionResult, for sessionID: UUID) throws {
        try Task.checkCancellation()
        guard sessions[sessionID] != nil else { throw IdentificationSessionStoreError.sessionNotFound }
        sessions[sessionID]?.result = result
        touch(sessionID)
    }

    func result(for sessionID: UUID) throws -> IdentificationSessionResult? {
        try Task.checkCancellation()
        guard let session = sessions[sessionID] else { throw IdentificationSessionStoreError.sessionNotFound }
        touch(sessionID)
        return session.result
    }

    func removeSession(_ sessionID: UUID) {
        retained.remove(sessionID)
        accessOrder.removeAll { $0 == sessionID }
        if let request = sessions.removeValue(forKey: sessionID)?.request,
           case .processedPhoto(let reference) = request.source {
            let stillReferenced = sessions.values.contains { session in
                if case .processedPhoto(let other) = session.request.source { return other.id == reference.id }
                return false
            }
            if !stillReferenced { photos.removeValue(forKey: reference.id) }
        }
    }
}
