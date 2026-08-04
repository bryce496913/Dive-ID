import Foundation

enum IdentificationSessionStoreError: Error { case sessionNotFound, photoNotFound, duplicateSession }

protocol IdentificationSessionStore: Sendable {
    func createSession(for request: IdentificationRequest, photo: ProcessedPhoto?) async throws -> UUID
    func request(for sessionID: UUID) async throws -> IdentificationRequest
    func photo(for reference: ProcessedPhotoReference) async throws -> ProcessedPhoto
    func saveResult(_ result: IdentificationSessionResult, for sessionID: UUID) async throws
    func result(for sessionID: UUID) async throws -> IdentificationSessionResult?
    func removeSession(_ sessionID: UUID) async
}

actor InMemoryIdentificationSessionStore: IdentificationSessionStore {
    private struct Session {
        let request: IdentificationRequest
        var result: IdentificationSessionResult?
    }

    private var sessions: [UUID: Session] = [:]
    private var photos: [UUID: ProcessedPhoto] = [:]

    func createSession(for request: IdentificationRequest, photo: ProcessedPhoto? = nil) throws -> UUID {
        guard sessions[request.id] == nil else { throw IdentificationSessionStoreError.duplicateSession }
        if let photo { photos[photo.id] = photo }
        sessions[request.id] = Session(request: request)
        return request.id
    }

    func request(for sessionID: UUID) throws -> IdentificationRequest {
        guard let session = sessions[sessionID] else { throw IdentificationSessionStoreError.sessionNotFound }
        return session.request
    }

    func photo(for reference: ProcessedPhotoReference) throws -> ProcessedPhoto {
        guard let photo = photos[reference.id] else { throw IdentificationSessionStoreError.photoNotFound }
        return photo
    }

    func saveResult(_ result: IdentificationSessionResult, for sessionID: UUID) throws {
        guard sessions[sessionID] != nil else { throw IdentificationSessionStoreError.sessionNotFound }
        sessions[sessionID]?.result = result
    }

    func result(for sessionID: UUID) throws -> IdentificationSessionResult? {
        guard let session = sessions[sessionID] else { throw IdentificationSessionStoreError.sessionNotFound }
        return session.result
    }

    func removeSession(_ sessionID: UUID) {
        if let request = sessions.removeValue(forKey: sessionID)?.request,
           case .processedPhoto(let reference) = request.source {
            photos.removeValue(forKey: reference.id)
        }
    }
}
