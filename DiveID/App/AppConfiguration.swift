import Foundation

enum IdentificationMode: String, Sendable { case mock, remote }
struct FeatureAvailability: Sendable {
    let descriptionIdentificationEnabled: Bool
    let photoIdentificationEnabled: Bool
}
struct AppConfiguration: Sendable {
    let identificationMode: IdentificationMode
    let apiBaseURL: URL?
    let features: FeatureAvailability

    static func bundled(bundle: Bundle = .main, arguments: [String] = ProcessInfo.processInfo.arguments) throws -> Self {
        if arguments.contains("-uiTesting") || arguments.contains("-useMockIdentification") {
            return .init(identificationMode: .mock, apiBaseURL: nil, features: .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: arguments.contains("-enableMockPhotoIdentification")))
        }
        guard let raw = bundle.object(forInfoDictionaryKey: "DIVE_ID_IDENTIFICATION_MODE") as? String,
              let mode = IdentificationMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw IdentificationServiceError.invalidConfiguration }
        let value = (bundle.object(forInfoDictionaryKey: "DIVE_ID_API_BASE_URL") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = value.flatMap { $0.isEmpty || $0.contains("$(") ? nil : URL(string: $0) }
        if mode == .remote {
            guard let url else { throw IdentificationServiceError.invalidConfiguration }
            _ = try DiveIDAPIConfiguration(baseURL: url)
        }
        return .init(identificationMode: mode, apiBaseURL: url, features: .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: false))
    }
}
