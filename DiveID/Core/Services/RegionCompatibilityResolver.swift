import Foundation

enum RegionCompatibility: Equatable, Sendable {
    case unspecified
    case compatible
    case conflicting
}

/// Resolves observed and supported geographic terms through the same hierarchy.
/// Pack aliases and species ranges remain data; broader geographic relationships live here.
struct RegionCompatibilityResolver: Sendable {
    private let parents: [String: Set<String>] = [
        "caribbean": ["western atlantic", "atlantic"], "western atlantic": ["atlantic"], "florida": ["western atlantic", "atlantic"], "bahamas": ["caribbean", "western atlantic", "atlantic"], "bermuda": ["western atlantic", "atlantic"], "gulf of mexico": ["western atlantic", "atlantic"], "belize": ["caribbean", "western atlantic", "atlantic"], "cayman islands": ["caribbean", "western atlantic", "atlantic"], "cozumel": ["caribbean", "western atlantic", "atlantic"], "bonaire": ["caribbean", "western atlantic", "atlantic"], "curaçao": ["caribbean", "western atlantic", "atlantic"], "curacao": ["caribbean", "western atlantic", "atlantic"], "aruba": ["caribbean", "western atlantic", "atlantic"], "turks and caicos": ["caribbean", "western atlantic", "atlantic"], "puerto rico": ["caribbean", "western atlantic", "atlantic"], "us virgin islands": ["caribbean", "western atlantic", "atlantic"], "british virgin islands": ["caribbean", "western atlantic", "atlantic"], "dominican republic": ["caribbean", "western atlantic", "atlantic"], "jamaica": ["caribbean", "western atlantic", "atlantic"],
        "fiji": ["indo-pacific", "pacific"], "indo-pacific": ["pacific", "indian"], "hawaii": ["pacific"]
    ]

    func compatibility(observedRegions: Set<String>, supportedRegions: Set<String>) -> RegionCompatibility {
        let observed = recognizedRegions(in: observedRegions)
        let supported = recognizedRegions(in: supportedRegions)
        guard !observed.isEmpty, !supported.isEmpty else { return .unspecified }

        for observedRegion in observed {
            let observedFamily = family(for: observedRegion)
            for supportedRegion in supported where !observedFamily.isDisjoint(with: family(for: supportedRegion)) {
                return .compatible
            }
        }
        return .conflicting
    }

    private func recognizedRegions(in regions: Set<String>) -> Set<String> {
        Set(regions.map(Self.normalize)).filter { CatalogueVocabulary.regions.contains($0) }
    }

    private static func normalize(_ value: String) -> String {
        LocalObservationParser.normalize(value).replacingOccurrences(of: "indo pacific", with: "indo-pacific")
    }

    private func family(for region: String) -> Set<String> {
        Set([region]).union(parents[region] ?? [])
    }
}
