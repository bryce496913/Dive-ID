import Foundation

struct ParsedObservation: Equatable, Sendable {
    let normalizedText: String
    let tokens: Set<String>
    let colors: Set<String>
    let markings: Set<String>
    let bodyShapes: Set<String>
    let habitats: Set<String>
    let regions: Set<String>
    let behaviors: Set<String>
    let categories: Set<String>
    let approximateSizeCentimeters: Double?
    let approximateDepthMeters: Double?
    var domainContradiction: ObservationDomainContradiction? = nil
}

/// Positive evidence about the subject, not a penalty for unknown vocabulary.
enum ObservationDomainContradiction: String, Equatable, Sendable {
    case amphibianSubject
}
