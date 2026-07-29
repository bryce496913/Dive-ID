import Observation
import SwiftUI

enum AppRoute: Hashable {
    case descriptionSearch
    case photoIdentification
    case identificationResults(IdentificationSource)
    case speciesDetail(Species, Double?)
    case savedSpecies
}

@MainActor @Observable
final class AppRouter {
    var path: [AppRoute] = []
    func navigate(to route: AppRoute) { path.append(route) }
}
