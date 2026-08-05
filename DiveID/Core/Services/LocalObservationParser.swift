import Foundation

protocol ObservationParsing: Sendable {
    func parse(_ description: String) async -> ParsedObservation
}

enum LocalObservationVocabulary {
    static let stopWords: Set<String> = ["a", "an", "and", "the", "with", "near", "on", "in", "at", "of", "to", "was", "it", "about", "approximately", "saw", "seen"]
    static let synonyms: [String: Set<String>] = [
        "blue": ["blue", "navy", "turquoise", "cyan"], "yellow": ["yellow", "gold", "golden"], "red": ["red", "reddish"], "white": ["white", "pale"], "black": ["black", "dark"], "orange": ["orange"], "silver": ["silver", "silvery"], "green": ["green"], "gray": ["gray", "grey"],
        "spots": ["spot", "spots", "spotted", "dots", "dotted"], "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars"], "spines": ["spine", "spines"], "tail": ["tail"], "shell": ["shell"], "teeth": ["teeth", "tooth", "jaw"],
        "reef": ["reef", "coral", "coral reef", "wall"], "sand": ["sand", "sandy", "sandy bottom"], "seagrass": ["seagrass", "sea grass"], "lagoon": ["lagoon"], "surface": ["surface"], "deep": ["deep"], "shallow": ["shallow", "near shore"],
        "flat": ["flat", "disc", "disc shaped", "broad"], "elongated": ["long", "elongated", "streamlined", "eel like"], "compressed": ["compressed", "oval", "round", "disk", "disk shaped"], "pointed": ["pointed"],
        "fish": ["fish"], "ray": ["ray", "eagle ray", "flat thing"], "turtle": ["turtle"], "shark": ["shark"], "eel": ["eel"], "octopus": ["octopus"], "squid": ["squid"], "crustacean": ["crab", "lobster", "shrimp", "crustacean"], "mollusk": ["mollusk", "conch"], "seahorse": ["seahorse"],
        "schooling": ["school", "schooling"], "solitary": ["alone", "solitary"], "hovering": ["hovering", "hover"], "bottom-swimming": ["bottom", "sand"], "feeding": ["feeding", "grazing"], "swimming": ["swimming", "cruising"]
    ]
    static let colors = Set(["blue", "yellow", "red", "white", "black", "orange", "silver", "green", "gray"])
    static let markings = Set(["spots", "stripes", "spines", "tail", "shell", "teeth", "patches", "saddles", "eye stripe", "fin edge", "beak", "barbels"])
    static let habitats = Set(["reef", "sand", "seagrass", "lagoon", "surface", "deep", "shallow", "rubble", "wall", "wreck", "mangrove", "open water", "anemone"])
    static let bodyShapes = Set(["flat", "elongated", "compressed", "pointed", "round", "oval", "torpedo", "serpentine", "disk"])
    static let categories = Set(["fish", "ray", "turtle", "shark", "eel", "octopus", "squid", "crustacean", "mollusk", "seahorse"])
    static let behaviors = Set(["schooling", "solitary", "hovering", "bottom-swimming", "feeding", "swimming", "grazing", "burrowing", "hiding", "cleaning", "resting", "open-water cruising", "anemone association"])
    static let regions: Set<String> = ["fiji", "pacific", "atlantic", "western atlantic", "caribbean", "indo-pacific", "hawaii", "indian", "florida", "bahamas", "bermuda", "gulf of mexico", "belize", "cayman islands", "cozumel", "bonaire", "curaçao", "curacao", "aruba", "turks and caicos", "puerto rico", "us virgin islands", "british virgin islands", "dominican republic", "jamaica"]
}

struct LocalObservationParser: ObservationParsing {
    func parse(_ description: String) async -> ParsedObservation {
        let normalized = Self.normalize(description)
        let raw = normalized.split(separator: " ").map(String.init)
        var tokens = Set(raw.map(Self.singular).filter { !LocalObservationVocabulary.stopWords.contains($0) })
        if normalized.contains("indo pacific") { tokens.insert("indo-pacific") }
        for (key, values) in LocalObservationVocabulary.synonyms where values.contains(where: { Self.matches($0, inTokens: tokens, normalizedText: normalized) }) { tokens.insert(key) }
        return ParsedObservation(normalizedText: normalized, tokens: tokens, colors: tokens.intersection(LocalObservationVocabulary.colors), markings: tokens.intersection(LocalObservationVocabulary.markings), bodyShapes: tokens.intersection(LocalObservationVocabulary.bodyShapes), habitats: tokens.intersection(LocalObservationVocabulary.habitats), regions: tokens.intersection(LocalObservationVocabulary.regions), behaviors: tokens.intersection(LocalObservationVocabulary.behaviors), categories: tokens.intersection(LocalObservationVocabulary.categories), approximateSizeCentimeters: Self.size(in: normalized, tokens: tokens), approximateDepthMeters: Self.depth(in: normalized, tokens: tokens))
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[-/]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9. ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
    static func singular(_ token: String) -> String { token.count > 3 && token.hasSuffix("s") ? String(token.dropLast()) : token }
    static func matches(_ synonym: String, inTokens tokens: Set<String>, normalizedText: String) -> Bool {
        let term = normalize(synonym)
        if term.contains(" ") { return normalizedText.range(of: #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![a-z0-9])"#, options: .regularExpression) != nil }
        return tokens.contains(singular(term))
    }
    static func size(in text: String, tokens: Set<String>) -> Double? {
        if text.contains("half a meter") || text.contains("half a metre") { return 50 }
        if tokens.contains("hand-sized") || text.contains("hand sized") { return 15 }
        if let v = measurement(in: text, kind: .size) { return v.sizeCentimeters }
        if tokens.contains("small") { return 10 }; if tokens.contains("medium") { return 40 }; if tokens.contains("large") { return 120 }
        return nil
    }
    static func depth(in text: String, tokens: Set<String>) -> Double? {
        if let v = measurement(in: text, kind: .depth) { return v.depthMeters }
        if tokens.contains("shallow") || tokens.contains("lagoon") || tokens.contains("surface") { return 3 }
        if tokens.contains("deep") { return 30 }
        return nil
    }
    enum MeasurementKind { case size, depth }
    struct Measurement { let value: Double; let unit: String; var sizeCentimeters: Double { unit == "m" ? value * 100 : unit == "cm" ? value : value * 2.54 }; var depthMeters: Double { unit == "ft" ? value * 0.3048 : value } }
    static func measurement(in text: String, kind: MeasurementKind) -> Measurement? {
        let unitPattern = #"(cm|centimeter|centimeters|inch|inches|m|meter|meters|metre|metres|ft|feet|foot)"#
        let number = #"([0-9]+(?:\.[0-9]+)?)"#
        let patterns: [String] = kind == .depth ? [#"(?:at|depth of|around)\s*"# + number + #"\s*"# + unitPattern + #"(?:\s*deep)?"#, number + #"\s*"# + unitPattern + #"\s*deep"#] : [number + #"\s*"# + unitPattern + #"\s*(?:long|length)"#, #"(?:length about|about|roughly)\s*"# + number + #"\s*"# + unitPattern + #"(?:\s*long)?"#]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges >= 3, let vr = Range(match.range(at: 1), in: text), let ur = Range(match.range(at: 2), in: text), let value = Double(text[vr]) {
                let rawUnit = String(text[ur]); let unit = ["meter":"m","meters":"m","metre":"m","metres":"m","centimeter":"cm","centimeters":"cm","inch":"inches","foot":"ft","feet":"ft" ][rawUnit] ?? rawUnit
                return Measurement(value: value, unit: unit)
            }
        }
        return nil
    }
}
