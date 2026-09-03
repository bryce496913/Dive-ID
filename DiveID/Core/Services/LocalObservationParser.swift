import Foundation

protocol ObservationParsing: Sendable {
    func parse(_ description: String) async -> ParsedObservation
}

enum LocalObservationVocabulary {
    static let stopWords: Set<String> = ["a", "an", "and", "the", "with", "near", "on", "in", "at", "of", "to", "was", "it", "about", "approximately", "saw", "seen"]
    static let synonyms: [String: Set<String>] = [
        "blue": ["blue", "navy", "turquoise", "cyan"], "yellow": ["yellow", "gold", "golden"], "red": ["red", "reddish"], "white": ["white", "pale"], "black": ["black", "dark"], "brown": ["brown"], "olive": ["olive"], "orange": ["orange"], "silver": ["silver", "silvery"], "green": ["green"], "gray": ["gray", "grey"],
        "spots": ["spot", "spots", "spotted", "dots", "dotted"], "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars"], "spines": ["spine", "spines"], "tail": ["tail"], "shell": ["shell"], "teeth": ["teeth", "tooth", "jaw"], "beak": ["beak", "beaked", "beak-like"],
        "reef": ["reef", "coral", "coral reef", "wall"], "sand": ["sand", "sandy", "sandy bottom"], "seagrass": ["seagrass", "sea grass"], "lagoon": ["lagoon"], "surface": ["surface"], "deep": ["deep"], "shallow": ["shallow", "near shore"],
        "flat": ["flat", "disc", "disc shaped", "broad"], "elongated": ["long", "elongated", "streamlined", "eel like"], "compressed": ["compressed", "oval", "round", "disk", "disk shaped"], "pointed": ["pointed"], "robust": ["robust"],
        "fish": ["fish"], "ray": ["ray", "eagle ray", "flat thing"], "turtle": ["turtle"], "shark": ["shark"], "eel": ["eel"], "octopus": ["octopus"], "squid": ["squid"], "crustacean": ["crab", "lobster", "shrimp", "crustacean"], "mollusk": ["mollusk", "conch"], "seahorse": ["seahorse"],
        "schooling": ["school", "schooling"], "solitary": ["alone", "solitary"], "hovering": ["hovering", "hover"], "bottom-swimming": ["bottom", "sand"], "feeding": ["feeding"], "grazing": ["grazer", "grazing", "graze"], "swimming": ["swimming", "cruising"],
        "squared head": ["squared head", "squared looking head", "square head", "square shaped head"]
    ]
}

struct LocalObservationParser: ObservationParsing {
    func parse(_ description: String) async -> ParsedObservation {
        let normalized = Self.normalize(description)
        let raw = normalized.split(separator: " ").map(String.init)
        var tokens = Set(raw.map(Self.singular).filter { !LocalObservationVocabulary.stopWords.contains($0) })
        if normalized.contains("indo pacific") { tokens.insert("indo-pacific") }
        for (key, values) in LocalObservationVocabulary.synonyms where values.contains(where: { Self.matches($0, inTokens: tokens, normalizedText: normalized) }) { tokens.insert(key) }
        let measurements = Self.measurements(in: normalized, tokens: tokens)
        return ParsedObservation(normalizedText: normalized, tokens: tokens, colors: tokens.intersection(CatalogueVocabulary.colors), markings: tokens.intersection(CatalogueVocabulary.markings), bodyShapes: tokens.intersection(CatalogueVocabulary.bodyShapes), habitats: tokens.intersection(CatalogueVocabulary.habitats), regions: tokens.intersection(CatalogueVocabulary.regions), behaviors: tokens.intersection(CatalogueVocabulary.behaviors), categories: tokens.intersection(CatalogueVocabulary.categories), approximateSizeCentimeters: measurements.sizeCentimeters, approximateDepthMeters: measurements.depthMeters)
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
        if term.contains(" ") {
            return tokens.contains(term) || normalizedText.range(of: #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: term) + #"(?![a-z0-9])"#, options: .regularExpression) != nil
        }
        return tokens.contains(singular(term))
    }
    struct ParsedMeasurements: Equatable, Sendable { let sizeCentimeters: Double?; let depthMeters: Double? }
    private enum MeasurementRole { case size, depth }
    private enum MeasurementUnit {
        case centimeters, meters, inches, feet

        init?(raw: String) {
            switch raw {
            case "cm", "centimeter", "centimeters": self = .centimeters
            case "m", "meter", "meters", "metre", "metres": self = .meters
            case "inch", "inches": self = .inches
            case "ft", "feet", "foot": self = .feet
            default: return nil
            }
        }

        func sizeCentimeters(for value: Double) -> Double {
            switch self {
            case .centimeters: value
            case .meters: value * 100
            case .inches: value * 2.54
            case .feet: value * 30.48
            }
        }

        func depthMeters(for value: Double) -> Double? {
            switch self {
            case .meters: value
            case .feet: value * 0.3048
            case .centimeters, .inches: nil
            }
        }
    }
    private struct MeasurementCandidate { let sourceRange: Range<String.Index>; let value: Double; let unit: MeasurementUnit; let role: MeasurementRole }

    static func measurements(in text: String, tokens: Set<String>) -> ParsedMeasurements {
        let sizeCandidate = explicitMeasurement(in: text, patterns: sizePatterns, role: .size)
        var size = sizeCandidate.map { $0.unit.sizeCentimeters(for: $0.value) }
        let depthCandidate = explicitMeasurement(in: text, patterns: depthPatterns, role: .depth)
        var depth = depthCandidate.flatMap { $0.unit.depthMeters(for: $0.value) }
        if size == nil, text.contains("half a meter") || text.contains("half a metre") { size = 50 }
        if size == nil, tokens.contains("hand-sized") || text.contains("hand sized") { size = 15 }
        if size == nil, tokens.contains("small") { size = 10 }
        if size == nil, tokens.contains("medium") { size = 40 }
        if size == nil, tokens.contains("large") { size = 120 }
        if depth == nil, tokens.contains("shallow") || tokens.contains("lagoon") || tokens.contains("surface") { depth = 3 }
        if depth == nil, tokens.contains("deep") { depth = 30 }
        return ParsedMeasurements(sizeCentimeters: size, depthMeters: depth)
    }

    private static let number = #"([0-9]+(?:\.[0-9]+)?)"#
    private static let unitPattern = #"(cm|centimeter|centimeters|inch|inches|m|meter|meters|metre|metres|ft|feet|foot)"#
    private static let depthPatterns = [
        #"(?:at|around|about)\s*"# + number + #"\s*"# + unitPattern + #"\s*deep"#,
        #"(?:at\s+)?(?:a\s+)?depth\s+of\s*"# + number + #"\s*"# + unitPattern,
        number + #"\s*"# + unitPattern + #"\s*deep"#,
        #"(?:^|\s)at\s*"# + number + #"\s*"# + unitPattern + #"(?:\s|$)"#
    ]
    private static let sizePatterns = [
        number + #"\s*"# + unitPattern + #"\s*(?:long|length)"#,
        #"(?:length\s+about|about|roughly|around)\s*"# + number + #"\s*"# + unitPattern + #"(?:\s*long)?"#,
        number + #"\s*(cm|centimeter|centimeters|inch|inches)"#
    ]

    private static func explicitMeasurement(in text: String, patterns: [String], role: MeasurementRole) -> MeasurementCandidate? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches where match.numberOfRanges >= 3 {
                guard let sourceRange = Range(match.range(at: 0), in: text), let valueRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text), let value = Double(text[valueRange]), let unit = MeasurementUnit(raw: String(text[unitRange])) else { continue }
                if role == .depth, unit.depthMeters(for: value) == nil { continue }
                return MeasurementCandidate(sourceRange: sourceRange, value: value, unit: unit, role: role)
            }
        }
        return nil
    }
}
