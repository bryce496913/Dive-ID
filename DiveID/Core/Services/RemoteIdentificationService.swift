import Foundation

enum IdentificationServiceError: Error, Equatable {
    case invalidConfiguration, unsupportedSource, noConnection, rateLimited, timeout, invalidResponse, unavailable, invalidRequest

    var userMessage: String {
        switch self {
        case .noConnection: "Dive ID could not connect. Check your internet connection and try again."
        case .rateLimited: "Dive ID is receiving too many requests right now. Please try again shortly."
        case .timeout: "Identification took too long. Please try again."
        case .invalidResponse: "Dive ID received an unexpected response. Please try again."
        default: "Identification is temporarily unavailable. Please try again."
        }
    }
}

struct DiveIDAPIConfiguration: Sendable {
    let baseURL: URL
    init(baseURL: URL) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1"].contains(baseURL.host)) else { throw IdentificationServiceError.invalidConfiguration }
        self.baseURL = baseURL
    }
    static func bundled(bundle: Bundle = .main) throws -> Self {
        guard let value = bundle.object(forInfoDictionaryKey: "DIVE_ID_API_BASE_URL") as? String, let url = URL(string: value), !value.contains("$(") else { throw IdentificationServiceError.invalidConfiguration }
        return try .init(baseURL: url)
    }
}

protocol HTTPTransport: Sendable { func data(for request: URLRequest) async throws -> (Data, URLResponse) }
extension URLSession: HTTPTransport {}

struct DiveIDAPIClient: Sendable {
    let configuration: DiveIDAPIConfiguration
    let transport: any HTTPTransport
    init(configuration: DiveIDAPIConfiguration, transport: any HTTPTransport = URLSession.shared) { self.configuration = configuration; self.transport = transport }

    func identify(request: IdentificationRequest) async throws -> [IdentificationMatch] {
        guard case .description(let text) = request.source else { throw IdentificationServiceError.unsupportedSource }
        let endpoint = configuration.baseURL.appending(path: "v1/identifications/description")
        var urlRequest = URLRequest(url: endpoint); urlRequest.httpMethod = "POST"; urlRequest.timeoutInterval = 35
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type"); urlRequest.setValue(request.id.uuidString, forHTTPHeaderField: "X-Request-ID")
        urlRequest.httpBody = try JSONEncoder.api.encode(APIRequest(requestId: request.id, description: text.trimmingCharacters(in: .whitespacesAndNewlines), context: request.context))
        let data: Data; let response: URLResponse
        do { (data, response) = try await transport.data(for: urlRequest) } catch is CancellationError { throw CancellationError() } catch let error as URLError { if error.code == .timedOut { throw IdentificationServiceError.timeout }; if error.code == .cancelled { throw CancellationError() }; throw IdentificationServiceError.noConnection }
        guard let http = response as? HTTPURLResponse else { throw IdentificationServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder.api.decode(APIErrorEnvelope.self, from: data))?.error.code
            switch code { case "RATE_LIMITED": throw IdentificationServiceError.rateLimited; case "IDENTIFICATION_TIMEOUT": throw IdentificationServiceError.timeout; case "INVALID_REQUEST", "DESCRIPTION_TOO_SHORT", "DESCRIPTION_TOO_LONG": throw IdentificationServiceError.invalidRequest; case "INVALID_PROVIDER_RESPONSE": throw IdentificationServiceError.invalidResponse; default: throw IdentificationServiceError.unavailable }
        }
        let decoded: APIResponse
        do { decoded = try JSONDecoder.api.decode(APIResponse.self, from: data) } catch { throw IdentificationServiceError.invalidResponse }
        guard decoded.requestId == request.id, decoded.matches.count <= 10 else { throw IdentificationServiceError.invalidResponse }
        var seen = Set<UUID>()
        return decoded.matches.sorted { $0.rank < $1.rank }.compactMap { match in
            guard seen.insert(match.speciesId).inserted else { return nil }
            let species = Species(id: match.speciesId, commonName: match.commonName, scientificName: match.scientificName, summary: match.explanation, visualCharacteristics: match.distinguishingFeatures, habitat: match.habitat, geographicRange: match.geographicRange, imageAssetName: nil)
            return IdentificationMatch(id: match.speciesId, species: species, rank: match.rank, score: match.matchScore ?? 0, scoreKind: .relativeMatch, strength: match.confidenceCategory, explanation: match.explanation, distinguishingFeatures: match.distinguishingFeatures, cautions: match.cautions, taxonomicResolution: match.taxonomicResolution)
        }
    }
}

struct RemoteMarineLifeIdentificationService: MarineLifeIdentificationService {
    let client: DiveIDAPIClient
    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] { try await client.identify(request: request) }
}

private struct APIRequest: Codable { let requestId: UUID; let description: String; let context: IdentificationContext }
private struct APIResponse: Codable { let requestId: UUID; let matches: [APIMatch] }
private struct APIMatch: Codable { let speciesId: UUID; let rank: Int; let commonName, scientificName: String; let taxonomicResolution: TaxonomicResolution; let confidenceCategory: MatchStrength; let matchScore: Double?; let explanation: String; let distinguishingFeatures: [String]; let habitat, geographicRange: String; let cautions: [String] }
private struct APIErrorEnvelope: Codable { struct Payload: Codable { let code: String }; let error: Payload }
private extension JSONEncoder { static var api: JSONEncoder { let value=JSONEncoder();value.dateEncodingStrategy = .iso8601;return value } }
private extension JSONDecoder { static var api: JSONDecoder { let value=JSONDecoder();value.dateDecodingStrategy = .iso8601;return value } }
