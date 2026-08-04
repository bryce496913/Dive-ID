import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router = AppRouter()
    private let identificationService: any MarineLifeIdentificationService
    private let savedRepository: any SavedIdentificationRepository
    private let sessionStore = InMemoryIdentificationSessionStore()
    private let photoProcessor = DefaultPhotoProcessingService()
    private let features: FeatureAvailability

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let mode: MockMarineLifeIdentificationService.Mode
        if let index = arguments.firstIndex(of: "-mockIdentificationMode"), arguments.indices.contains(index + 1) {
            switch arguments[index + 1] {
            case "empty": mode = .empty
            case "failure": mode = .failure
            default: mode = .success
            }
        } else {
            mode = .success
        }
        let configuration = try? AppConfiguration.bundled(arguments: arguments)
        features = configuration?.features ?? .init(descriptionIdentificationEnabled: true, photoIdentificationEnabled: false)
        if configuration?.identificationMode == .mock {
            identificationService = MockMarineLifeIdentificationService(delay: arguments.contains("-uiTesting") ? .zero : .milliseconds(450), mode: mode)
        } else if let url = configuration?.apiBaseURL, let apiConfiguration = try? DiveIDAPIConfiguration(baseURL: url) {
            identificationService = RemoteMarineLifeIdentificationService(client: DiveIDAPIClient(configuration: apiConfiguration))
        } else {
            identificationService = UnconfiguredMarineLifeIdentificationService()
        }
        savedRepository = (try? JSONSavedIdentificationRepository()) ?? InMemorySavedIdentificationRepository()
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                router: router,
                identificationService: identificationService,
                savedRepository: savedRepository,
                sessionStore: sessionStore,
                photoProcessor: photoProcessor
                , features: features
            )
            .preferredColorScheme(.dark)
        }
    }
}

private struct UnconfiguredMarineLifeIdentificationService: MarineLifeIdentificationService {
    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] { throw IdentificationServiceError.invalidConfiguration }
}
