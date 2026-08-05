import Foundation

protocol ObservationParsing: Sendable {
    func parse(_ description: String) async -> ParsedObservation
}

enum LocalObservationVocabulary {
    static let stopWords: Set<String> = ["a", "an", "and", "the", "with", "near", "on", "in", "at", "of", "to", "was", "it", "about", "approximately", "saw", "seen"]
    static let synonyms: [String: Set<String>] = [
        "blue": ["blue", "navy", "turquoise", "cyan"], "yellow": ["yellow", "gold", "golden"], "red": ["red", "reddish"], "white": ["white", "pale"], "black": ["black", "dark"], "orange": ["orange"], "silver": ["silver", "silvery"], "green": ["green"],
        "spots": ["spot", "spots", "spotted", "dots", "dotted"], "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars"], "spines": ["spine", "spines", "rays"], "tail": ["tail"], "shell": ["shell"], "teeth": ["teeth", "tooth", "jaw"],
        "reef": ["reef", "coral", "coral reef", "wall"], "sand": ["sand", "sandy"], "seagrass": ["seagrass", "grass"], "lagoon": ["lagoon"], "surface": ["surface"], "deep": ["deep"], "shallow": ["shallow", "near shore"],
        "flat": ["flat", "disc", "disc-shaped", "broad"], "elongated": ["long", "elongated", "streamlined", "eel-like"], "compressed": ["compressed", "oval", "round", "disk", "disk-shaped"], "pointed": ["pointed"],
        "fish": ["fish"], "ray": ["ray"], "turtle": ["turtle"], "shark": ["shark"],
        "schooling": ["school", "schooling"], "solitary": ["alone", "solitary"], "hovering": ["hovering", "hover"], "bottom-swimming": ["bottom", "sand"], "feeding": ["feeding", "grazing"], "swimming": ["swimming", "cruising"]
    ]
    static let colors = Set(["blue", "yellow", "red", "white", "black", "orange", "silver", "green"])
    static let markings = Set(["spots", "stripes", "spines", "tail", "shell", "teeth"])
    static let habitats = Set(["reef", "sand", "seagrass", "lagoon", "surface", "deep", "shallow"])
    static let bodyShapes = Set(["flat", "elongated", "compressed", "pointed"])
    static let categories = Set(["fish", "ray", "turtle", "shark"])
    static let behaviors = Set(["schooling", "solitary", "hovering", "bottom-swimming", "feeding", "swimming"])
    static let regions: Set<String> = ["fiji", "pacific", "atlantic", "caribbean", "indo-pacific", "hawaii", "indian"]
}

struct LocalObservationParser: ObservationParsing {
    func parse(_ description: String) async -> ParsedObservation {
        let normalized = Self.normalize(description)
        let raw = normalized.split(separator: " ").map(String.init)
        var tokens = Set(raw.map(Self.singular).filter { !LocalObservationVocabulary.stopWords.contains($0) })
        for (key, values) in LocalObservationVocabulary.synonyms where values.contains(where: { normalized.contains($0) || tokens.contains($0) }) { tokens.insert(key) }
        return ParsedObservation(
            normalizedText: normalized,
            tokens: tokens,
            colors: tokens.intersection(LocalObservationVocabulary.colors),
            markings: tokens.intersection(LocalObservationVocabulary.markings),
            bodyShapes: tokens.intersection(LocalObservationVocabulary.bodyShapes),
            habitats: tokens.intersection(LocalObservationVocabulary.habitats),
            regions: tokens.intersection(LocalObservationVocabulary.regions),
            behaviors: tokens.intersection(LocalObservationVocabulary.behaviors),
            categories: tokens.intersection(LocalObservationVocabulary.categories),
            approximateSizeCentimeters: Self.size(in: normalized, tokens: tokens),
            approximateDepthMeters: Self.depth(in: normalized, tokens: tokens)
        )
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^a-z0-9.\- ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    static func singular(_ token: String) -> String { token.count > 3 && token.hasSuffix("s") ? String(token.dropLast()) : token }
    static func size(in text: String, tokens: Set<String>) -> Double? {
        if let v = firstNumber(text, units: ["cm", "centimeter", "centimeters"]) { return v }
        if let v = firstNumber(text, units: ["m", "meter", "meters", "metre", "metres"]) { return v * 100 }
        if text.contains("half a meter") || text.contains("half a metre") { return 50 }
        if tokens.contains("hand-sized") || text.contains("hand sized") { return 15 }
        if tokens.contains("small") { return 10 }
        if tokens.contains("medium") { return 40 }
        if tokens.contains("large") { return 120 }
        return nil
    }
    static func depth(in text: String, tokens: Set<String>) -> Double? {
        if let v = firstNumber(text, units: ["m deep", "meters", "metres", "meter", "metre", "m"]) { return v }
        if tokens.contains("shallow") || tokens.contains("lagoon") || tokens.contains("surface") { return 3 }
        if tokens.contains("deep") { return 30 }
        return nil
    }
    static func firstNumber(_ text: String, units: [String]) -> Double? {
        for unit in units {
            let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*"# + NSRegularExpression.escapedPattern(for: unit) + #"\b"#
            if let range = text.range(of: pattern, options: .regularExpression) {
                let value = text[range].split { !$0.isNumber && $0 != "." }.first.flatMap { Double($0) }
                if let value { return value }
            }
        }
        return nil
    }
}
