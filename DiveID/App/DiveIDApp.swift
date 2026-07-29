import SwiftUI

@main
struct DiveIDApp: App {
    @State private var router = AppRouter()
    private let identificationService = MockMarineLifeIdentificationService()
    private let savedRepository = InMemorySavedSpeciesRepository()

    var body: some Scene {
        WindowGroup {
            RootView(router: router, identificationService: identificationService, savedRepository: savedRepository)
        }
    }
}
