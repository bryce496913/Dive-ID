import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router = AppRouter()
    private let identificationService: any MarineLifeIdentificationService
    private let savedRepository: any SavedSpeciesRepository
    private let sessionStore = InMemoryIdentificationSessionStore()
    private let photoProcessor = DefaultPhotoProcessingService()

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
        if arguments.contains("-uiTesting") || arguments.contains("-useMockIdentification") {
            identificationService = MockMarineLifeIdentificationService(delay: arguments.contains("-uiTesting") ? .zero : .milliseconds(450), mode: mode)
        } else if let configuration = try? DiveIDAPIConfiguration.bundled() {
            identificationService = RemoteMarineLifeIdentificationService(client: DiveIDAPIClient(configuration: configuration))
        } else {
            identificationService = UnconfiguredMarineLifeIdentificationService()
        }
        savedRepository = (try? JSONSavedSpeciesRepository()) ?? InMemorySavedSpeciesRepository()
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                router: router,
                identificationService: identificationService,
                savedRepository: savedRepository,
                sessionStore: sessionStore,
                photoProcessor: photoProcessor
            )
            .preferredColorScheme(.dark)
        }
    }
}

private struct UnconfiguredMarineLifeIdentificationService: MarineLifeIdentificationService {
    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] { throw IdentificationServiceError.invalidConfiguration }
}
