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
        "tropical pacific": ["pacific"], "australia": ["indo-pacific", "pacific", "indian"], "philippines": ["indo-pacific", "pacific"], "indonesia": ["indo-pacific", "pacific", "indian"], "fiji": ["indo-pacific", "pacific"], "indo-pacific": ["pacific", "indian"], "hawaii": ["pacific"]
    ]

    func compatibility(observedRegions: Set<String>, supportedRegions: Set<String>) -> RegionCompatibility {
        let observed = recognizedRegions(in: observedRegions)
        let supported = recognizedRegions(in: supportedRegions)
        guard !observed.isEmpty, !supported.isEmpty else { return .unspecified }

        let matches = observed.map { observedRegion in
            supported.contains { !family(for: observedRegion).isDisjoint(with: family(for: $0)) }
        }
        // Multiple locations spanning compatible and incompatible regions do not
        // establish which location describes the sighting.
        if matches.allSatisfy({ $0 }) { return .compatible }
        if matches.allSatisfy({ !$0 }) { return .conflicting }
        return .unspecified
    }

    // These additional names are the existing TropicalPacific manifest aliases,
    // not new species range terms in the controlled catalogue vocabulary.
    static let locationNames = CatalogueVocabulary.regions.union([
        "tropical pacific", "australia", "philippines", "indonesia"
    ])

    /// Match complete phrases in the original description, before biological
    /// token singularization. Longest matches consume their component words.
    static func locations(in text: String) -> Set<String> {
        let words = locationWords(text)
        let names = locationNames.sorted {
            let lhs = locationWords($0).count, rhs = locationWords($1).count
            return lhs == rhs ? $0 < $1 : lhs > rhs
        }
        var occupied: Set<Int> = [], result: Set<String> = []
        for name in names {
            let phrase = locationWords(name)
            guard words.count >= phrase.count else { continue }
            for start in 0...(words.count - phrase.count) {
                let span = start..<(start + phrase.count)
                if occupied.isDisjoint(with: span), Array(words[span]) == phrase {
                    result.insert(canonical(name))
                    occupied.formUnion(span)
                }
            }
        }
        return result
    }

    private func recognizedRegions(in regions: Set<String>) -> Set<String> {
        Set(regions.map(Self.canonical)).intersection(Set(Self.locationNames.map(Self.canonical)))
    }

    private static func locationWords(_ value: String) -> [String] {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func canonical(_ value: String) -> String {
        let phrase = locationWords(value).joined(separator: " ")
        return phrase == "indo pacific" ? "indo-pacific" : phrase
    }

    private func family(for region: String) -> Set<String> {
        Set([region]).union(parents[region] ?? [])
    }
}
