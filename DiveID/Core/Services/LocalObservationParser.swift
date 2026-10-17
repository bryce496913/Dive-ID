import Foundation

protocol ObservationParsing: Sendable {
    func parse(_ description: String) async -> ParsedObservation
}

enum LocalObservationVocabulary {
    static let stopWords: Set<String> = ["a", "an", "and", "the", "with", "near", "on", "in", "at", "of", "to", "was", "it", "about", "approximately", "saw", "seen"]
    static let synonyms: [String: Set<String>] = [
        "blue": ["blue", "navy", "turquoise", "cyan"], "yellow": ["yellow", "gold", "golden"], "red": ["red", "reddish"], "white": ["white"], "black": ["black", "dark"], "brown": ["brown"], "olive": ["olive"], "orange": ["orange"], "silver": ["silver", "silvery"], "green": ["green"], "gray": ["gray", "grey"],
        "patches": ["patch", "patches"], "spots": ["spot", "spots", "spotted", "dots", "dotted"], "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars"], "spines": ["spine", "spines", "spiny", "spiky", "needles"], "tail": ["tail"], "shell": ["shell"], "teeth": ["teeth", "tooth", "jaw"], "beak": ["beak", "beaked", "beak-like"],
        "reef": ["reef", "coral", "coral reef", "wall"], "sand": ["sand", "sandy", "sandy bottom"], "seagrass": ["seagrass", "sea grass"], "lagoon": ["lagoon"], "surface": ["surface"], "deep": ["deep"], "shallow": ["shallow", "near shore"],
        "flat": ["flat", "disc", "disc shaped", "broad"], "elongated": ["long", "elongated", "streamlined", "eel like"], "compressed": ["compressed", "oval", "round", "disk", "disk shaped"], "pointed": ["pointed"], "robust": ["robust"],
        "fish": ["fish"], "ray": ["ray", "eagle ray", "flat thing"], "turtle": ["turtle"], "shark": ["shark"], "eel": ["eel"], "octopus": ["octopus"], "squid": ["squid"], "crustacean": ["crab", "lobster", "shrimp", "crustacean"], "mollusk": ["mollusk", "conch"], "seahorse": ["seahorse"],
        "schooling": ["school", "schooling"], "solitary": ["alone", "solitary"], "hovering": ["hovering", "hover"], "bottom-swimming": ["bottom", "sand"], "feeding": ["feeding"], "grazing": ["grazer", "grazing", "graze"], "swimming": ["swimming", "cruising"],
        "squared head": ["squared head", "squared looking head", "square head", "square shaped head"]
    ]
}

struct LocalObservationParser: ObservationParsing {
    func parse(_ description: String) async -> ParsedObservation {
        let affirmative = Self.affirmativeEvidence(in: description)
        let normalized = Self.normalize(affirmative)
        let traitText = Self.normalize(Self.withoutMeasurementRoleWords(in: affirmative))
        // Keep decimal punctuation in `normalized` for measurement parsing, but do
        // not let sentence punctuation become part of an observation token.
        let morphology = MorphologyVocabulary.concepts(in: traitText)
        let raw = traitText.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var tokens = Set(raw.map(Self.singular).filter { !LocalObservationVocabulary.stopWords.contains($0) })
        tokens.remove("leaflike")
        tokens.formUnion(morphology)
        if normalized.contains("indo pacific") { tokens.insert("indo-pacific") }
        for (key, values) in LocalObservationVocabulary.synonyms where values.contains(where: { Self.matches($0, inTokens: tokens, normalizedText: traitText) }) { tokens.insert(key) }
        // Measurement ranges must refer to the user's original string. In
        // particular, normalization can remove multi-byte Unicode characters
        // and make ranges from the normalized string invalid for the source.
        let measurements = Self.measurements(in: affirmative, tokens: tokens)
        return ParsedObservation(normalizedText: normalized, tokens: tokens, colors: tokens.intersection(CatalogueVocabulary.colors), markings: tokens.intersection(CatalogueVocabulary.markings), bodyShapes: tokens.intersection(CatalogueVocabulary.bodyShapes), habitats: tokens.intersection(CatalogueVocabulary.habitats), regions: RegionCompatibilityResolver.locations(in: description), behaviors: tokens.intersection(CatalogueVocabulary.behaviors), categories: tokens.intersection(CatalogueVocabulary.categories), approximateSizeCentimeters: measurements.sizeCentimeters, approximateDepthMeters: measurements.depthMeters, colorEvidenceGroups: AppearanceEvidenceVocabulary.colorGroups(in: affirmative, colors: tokens.intersection(CatalogueVocabulary.colors)), appearanceRelationships: AppearanceEvidenceVocabulary.appearanceRelationships(in: affirmative), domainContradiction: MarineObservationDomainPolicy.contradiction(in: description))
    }

    /// Negated clauses do not assert positive traits or exact species names.
    /// Keep the boundary at punctuation/conjunctions so later positive evidence
    /// survives. This does not infer absence of every component of a compound
    /// phrase: "no pink tail" is not evidence that an animal has no tail.
    static func affirmativeEvidence(in text: String) -> String {
        text.replacingOccurrences(of: #"\b(?:no|not(?!\s+only\b)|without)\b(?:(?!\b(?:but|and)\b)[^,;.!?])*"#,
            with: " ", options: [.regularExpression, .caseInsensitive])
    }

    private static func withoutMeasurementRoleWords(in text: String) -> String {
        var result = text
        // Work backwards in the original string to preserve all other ranges.
        for candidate in resolvedMeasurementCandidates(in: text).reversed() {
            let suffix = text[candidate.sourceRange.upperBound...]
            if let role = suffix.range(of: #"^\s*(?:long|length|deep|depth)\b"#, options: [.regularExpression, .caseInsensitive]) {
                result.replaceSubrange(role, with: " ")
            }
        }
        return result
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
    private struct MeasurementCandidate {
        /// The numeric value and unit occurrence in the original input.
        let sourceRange: Range<String.Index>
        let value: Double
        let unit: MeasurementUnit
        let role: MeasurementRole
        /// Explicit role words (`deep`, `depth`, `long`, or `length`) outrank
        /// looser forms such as `about 10 m` when interpretations overlap.
        let contextStrength: Int
        let patternOrder: Int
    }

    private struct MeasurementPattern {
        let expression: String
        let contextStrength: Int
    }

    static func measurements(in text: String, tokens: Set<String>) -> ParsedMeasurements {
        let candidates = resolvedMeasurementCandidates(in: text)
        let sizeCandidate = candidates.first { $0.role == .size }
        var size = sizeCandidate.map { $0.unit.sizeCentimeters(for: $0.value) }
        let depthCandidate = candidates.first { $0.role == .depth }
        var depth = depthCandidate.flatMap { $0.unit.depthMeters(for: $0.value) }
        let normalizedText = normalize(text)
        if size == nil, normalizedText.contains("half a meter") || normalizedText.contains("half a metre") { size = 50 }
        if size == nil, tokens.contains("hand-sized") || normalizedText.contains("hand sized") { size = 15 }
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
        MeasurementPattern(expression: #"(?:at|around|about)\s*"# + number + #"\s*"# + unitPattern + #"\s*deep"#, contextStrength: 2),
        MeasurementPattern(expression: #"(?:at\s+)?(?:a\s+)?depth(?:\s+of)?\s*"# + number + #"\s*"# + unitPattern, contextStrength: 2),
        MeasurementPattern(expression: number + #"\s*"# + unitPattern + #"\s*(?:deep|depth)"#, contextStrength: 2),
        MeasurementPattern(expression: #"(?:^|\s)at\s*"# + number + #"\s*"# + unitPattern + #"(?:\s|$)"#, contextStrength: 1)
    ]
    private static let sizePatterns = [
        MeasurementPattern(expression: number + #"\s*"# + unitPattern + #"\s*(?:long|length)"#, contextStrength: 2),
        MeasurementPattern(expression: #"(?:length\s+about|about|roughly|around)\s*"# + number + #"\s*"# + unitPattern + #"(?:\s*long)?"#, contextStrength: 1),
        MeasurementPattern(expression: number + #"\s*(cm|centimeter|centimeters|inch|inches)"#, contextStrength: 0)
    ]

    private static func measurementCandidates(in text: String, patterns: [MeasurementPattern], role: MeasurementRole) -> [MeasurementCandidate] {
        var candidates: [MeasurementCandidate] = []
        for (patternOrder, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern.expression, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches where match.numberOfRanges >= 3 {
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let unitRange = Range(match.range(at: 2), in: text),
                      let value = Double(text[valueRange]),
                      let unit = MeasurementUnit(raw: String(text[unitRange]).lowercased()) else { continue }
                if role == .depth, unit.depthMeters(for: value) == nil { continue }
                candidates.append(MeasurementCandidate(
                    sourceRange: valueRange.lowerBound..<unitRange.upperBound,
                    value: value,
                    unit: unit,
                    role: role,
                    contextStrength: pattern.contextStrength,
                    patternOrder: patternOrder
                ))
            }
        }
        return candidates
    }

    private static func resolvedMeasurementCandidates(in text: String) -> [MeasurementCandidate] {
        let candidates = measurementCandidates(in: text, patterns: sizePatterns, role: .size)
            + measurementCandidates(in: text, patterns: depthPatterns, role: .depth)
        let preferred = candidates.sorted {
            if $0.contextStrength != $1.contextStrength { return $0.contextStrength > $1.contextStrength }
            if $0.sourceRange.lowerBound != $1.sourceRange.lowerBound { return $0.sourceRange.lowerBound < $1.sourceRange.lowerBound }
            return $0.patternOrder < $1.patternOrder
        }

        // Once one role claims a numeric/unit occurrence, discard every other
        // interpretation whose original-source range overlaps it. Disjoint
        // occurrences remain available even when their values and units match.
        var resolved: [MeasurementCandidate] = []
        for candidate in preferred where !resolved.contains(where: { $0.sourceRange.overlaps(candidate.sourceRange) }) {
            resolved.append(candidate)
        }
        return resolved.sorted { $0.sourceRange.lowerBound < $1.sourceRange.lowerBound }
    }
}

/// The bundled marine catalogue has no amphibian category. Only an explicit
/// subject assertion is decisive; comparisons, negation, uncertainty and nouns
/// mentioned as objects must not turn into catalogue-wide exclusions.
/// This deliberately small grammar is not a general natural-language classifier.
enum MarineObservationDomainPolicy {
    private static let amphibians: Set<String> = ["frog", "frogs", "toad", "toads", "amphibian", "amphibians"]
    private static let modifiers = CatalogueVocabulary.colors.union([
        "a", "an", "the", "this", "that", "small", "large", "tiny", "little", "big",
        "spotted", "striped", "banded", "freshwater", "fresh", "water", "terrestrial"
    ])
    private static let nonAssertions: Set<String> = [
        "not", "no", "never", "without", "maybe", "perhaps", "possibly", "probably",
        "or", "if", "whether", "like", "unlike", "resembles", "resembling"
    ]
    private static let comparisonHeads: Set<String> = [
        "like", "shaped", "looking", "face", "faces", "head", "heads", "mouth", "eyes", "fish"
    ]

    static func contradiction(in description: String) -> ObservationDomainContradiction? {
        // A question does not assert the subject's identity.
        guard !description.contains("?") else { return nil }
        for clause in description.components(separatedBy: CharacterSet(charactersIn: ".!;\n")) {
            var words = clause.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            guard Set(words).isDisjoint(with: nonAssertions) else { continue }
            let prefixes = [
                ["i", "saw"], ["we", "saw"], ["i", "observed"], ["we", "observed"],
                ["i", "spotted"], ["we", "spotted"], ["i", "found"], ["we", "found"],
                ["it", "is"], ["it", "was"], ["this", "is"], ["this", "was"],
                ["that", "is"], ["that", "was"], ["the", "subject", "is"], ["the", "subject", "was"]
            ]
            if let prefix = prefixes.first(where: { words.starts(with: $0) }) {
                words.removeFirst(prefix.count)
            }
            guard let subject = words.firstIndex(where: { amphibians.contains($0) }),
                  words[..<subject].allSatisfy({ modifiers.contains($0) }) else { continue }
            let suffix = words.dropFirst(subject + 1)
            if let next = suffix.first, comparisonHeads.contains(next) { continue }
            // Coordinated animal subjects are ambiguous, not a single decisive
            // amphibian assertion (e.g. "a frog and a fish swimming").
            if suffix.contains("and"), !Set(suffix).isDisjoint(with: CatalogueVocabulary.categories) { continue }
            return .amphibianSubject
        }
        return nil
    }
}


/// Relational appearance evidence is extracted from affirmative phrases, never
/// inferred by combining independent catalogue color and marking lists.
enum AppearanceEvidenceVocabulary {
    private static let colorWords = LocalObservationVocabulary.synonyms
        .filter { CatalogueVocabulary.colors.contains($0.key) }
        .reduce(into: [String: String]()) { result, entry in
            for word in entry.value { result[word] = entry.key }
        }
    private static let markingWords = LocalObservationVocabulary.synonyms
        .filter { ["stripes", "spots", "patches"].contains($0.key) }
        .reduce(into: [String: String]()) { result, entry in
            for word in entry.value { result[word] = entry.key }
        }
    private static func alternatives(_ words: [String: String]) -> String {
        words.keys.sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|")
    }
    private static let color = alternatives(colorWords)
    private static let hueColor = alternatives(colorWords.filter { $0.key != "dark" })
    private static let marking = alternatives(markingWords)
    private static let compoundRegex = try! NSRegularExpression(pattern: "\\b(" + hueColor + ")[ -]+(" + hueColor + ")\\b", options: [.caseInsensitive])
    private static let hyphenatedHueRegex = try! NSRegularExpression(pattern: "\\b(" + hueColor + ")\\s*[-–]\\s*(" + hueColor + ")\\b", options: [.caseInsensitive])
    private static let markingRegex = try! NSRegularExpression(pattern: "\\b(" + color + ")(?:[ -]+(?:thin|fine|broad|narrow|small|large))?[ -]+(" + marking + ")\\b", options: [.caseInsensitive])

    private static func captures(_ regex: NSRegularExpression, in text: String) -> [[String]] {
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]).lowercased() } ?? ""
            }
        }
    }
    static func colorGroups(in text: String, colors: Set<String>) -> [Set<String>] {
        var groups = colors.sorted().map { Set([$0]) }
        // Direct compound hues (orange-red) are one clue. Coordinated colors
        // (black-and-white, blue and yellow) remain distinct observations.
        for pair in captures(hyphenatedHueRegex, in: text) {
            guard let first = colorWords[pair[0]], let second = colorWords[pair[1]] else { continue }
            let members = Set([first, second]).intersection(colors)
            let connected = groups.filter { !$0.isDisjoint(with: members) }.reduce(members) { $0.union($1) }
            groups.removeAll { !$0.isDisjoint(with: connected) }
            if !connected.isEmpty { groups.append(connected) }
        }
        return groups.sorted { $0.sorted().joined() < $1.sorted().joined() }
    }
    static func appearanceRelationships(in text: String) -> Set<String> {
        let affirmative = LocalObservationParser.affirmativeEvidence(in: text)
        // Only adjacency within a phrase establishes the relationship. Commas,
        // semicolons and document separators cannot join an unordered trait list.
        let markings = Set(captures(markingRegex, in: affirmative).compactMap { pair -> String? in
            guard let color = colorWords[pair[0]], let marking = markingWords[pair[1]] else { return nil }
            return color + " " + marking
        })
        let compounds = captures(compoundRegex, in: affirmative).compactMap { pair -> String? in
            guard let first = colorWords[pair[0]], let second = colorWords[pair[1]], first != second else { return nil }
            return [first, second].sorted().joined(separator: "-") + " hue"
        }
        return markings.union(compounds)
    }
}
