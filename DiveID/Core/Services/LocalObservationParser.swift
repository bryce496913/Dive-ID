import Foundation

protocol ObservationParsing: Sendable {
    func parse(_ description: String) async -> ParsedObservation
}

enum LocalObservationVocabulary {
    static let stopWords: Set<String> = ["a", "an", "and", "the", "with", "near", "on", "in", "at", "of", "to", "was", "it", "about", "approximately", "saw", "seen"]
    static let synonyms: [String: Set<String>] = [
        "blue": ["blue", "navy", "turquoise", "cyan"], "yellow": ["yellow", "gold", "golden"], "red": ["red", "reddish", "maroon"], "white": ["white"], "black": ["black", "dark"], "brown": ["brown"], "olive": ["olive"], "orange": ["orange"], "silver": ["silver", "silvery"], "green": ["green"], "gray": ["gray", "grey"],
        "patches": ["patch", "patches"], "spots": ["spot", "spots", "spotted", "dots", "dotted"], "stripes": ["stripe", "stripes", "striped", "band", "bands", "banded", "bar", "bars"], "spines": ["spine", "spines", "spiny", "spiky", "needles"], "tail": ["tail"], "shell": ["shell"], "teeth": ["teeth", "tooth", "jaw"], "beak": ["beak", "beaked", "beak-like"],
        "reef": ["reef", "coral", "coral reef", "wall"], "sand": ["sand", "sandy", "sandy bottom"], "seagrass": ["seagrass", "sea grass"], "lagoon": ["lagoon"], "surface": ["surface"], "deep": ["deep"], "shallow": ["shallow", "near shore"],
        "flat": ["flat", "disc", "disc shaped", "broad"], "elongated": ["long", "elongated", "streamlined", "eel like"], "compressed": ["compressed", "oval", "round", "disk", "disk shaped"], "pointed": ["pointed"], "robust": ["robust"],
        "fish": ["fish"], "ray": ["ray", "eagle ray", "flat thing"], "turtle": ["turtle"], "shark": ["shark"], "eel": ["eel"], "octopus": ["octopus"], "squid": ["squid"], "crustacean": ["crab", "lobster", "shrimp", "crustacean"], "mollusk": ["mollusk", "conch"], "seahorse": ["seahorse"],
        "sea cucumber": ["sea cucumber", "sea cucumbers", "holothurian"], "sea urchin": ["sea urchin", "urchin"], "jellyfish": ["jellyfish", "sea jelly", "sea jellies", "medusa"], "worm": ["worm"], "sea squirt": ["sea squirt", "sea squirts", "tunicate", "ascidian"], "horseshoe crab": ["horseshoe crab", "horseshoe crabs"],
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
        // "Birdlike" or "leaf-like" also names the thing it resembles.
        tokens.formUnion(raw.compactMap(Self.likeStem))
        tokens.formUnion(morphology)
        if normalized.contains("indo pacific") { tokens.insert("indo-pacific") }
        tokens = Self.expandingSynonyms(tokens, normalizedText: traitText)
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
        negatedPhrase.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    // Compiled once: compiling per call dominated building the search index.
    private static let negatedPhrase = try! NSRegularExpression(
        pattern: #"\b(?:no|not(?!\s+only\b)|without)\b(?:(?!\b(?:but|and)\b)[^,;.!?])*"#, options: [.caseInsensitive])

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

    /// Lowercases and trims, then turns every run of characters other than a–z, 0–9 and "."
    /// into one space. One pass; the same result as the earlier three regex replacements
    /// (`[-/]+`, `[^a-z0-9. ]+`, `\s+` → " "), which `LocalObservationParserTests` checks.
    static func normalize(_ text: String) -> String {
        if let ascii = normalizeASCII(text) { return ascii }
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39, 0x2E:
                if pendingSpace { result.append(" "); pendingSpace = false }
                result.append(scalar)
            default:
                pendingSpace = true
            }
        }
        if pendingSpace { result.append(" ") }
        return String(result)
    }

    /// The same normalization on UTF-8 bytes. Every non-ASCII character is a separator
    /// either way, except the two whose lowercase is ASCII (İ U+0130, Kelvin sign U+212A)
    /// and non-ASCII whitespace at either end, which the general path trims; for those
    /// this returns nil.
    private static func normalizeASCII(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var start = 0, end = bytes.count
        // ASCII whitespace and newlines, as trimmed by `.whitespacesAndNewlines`.
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (0x09...0x0D).contains(byte) }
        while start < end, isSpace(bytes[start]) { start += 1 }
        while start < end, isSpace(bytes[end - 1]) { end -= 1 }
        if start < end, bytes[start] >= 0x80 || bytes[end - 1] >= 0x80 { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(end - start)
        var pendingSpace = false
        var index = start
        while index < end {
            let byte = bytes[index]
            if byte >= 0x80 {
                if byte == 0xC4, index + 1 < end, bytes[index + 1] == 0xB0 { return nil }
                if byte == 0xE2, index + 2 < end, bytes[index + 1] == 0x84, bytes[index + 2] == 0xAA { return nil }
                pendingSpace = true
                index += 1
                continue
            }
            let lower = (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
            switch lower {
            case 0x61...0x7A, 0x30...0x39, 0x2E:
                if pendingSpace { output.append(0x20); pendingSpace = false }
                output.append(lower)
            default:
                pendingSpace = true
            }
            index += 1
        }
        if pendingSpace { output.append(0x20) }
        return String(decoding: output, as: UTF8.self)
    }
    /// "birdlike" -> "bird"; nil for words that do not end in a "-like" suffix.
    static func likeStem(_ word: String) -> String? {
        let lower = word.lowercased()
        guard lower.count > 6, lower.hasSuffix("like") else { return nil }
        return singular(String(lower.dropLast(4)))
    }
    /// Adds the key of every synonym rule that matches the description's own tokens.
    /// Rules see only `tokens` as given, never a key another rule added, so expansion
    /// is a single pass with no chaining: "sandy" adds "sand", but "sand" does not then
    /// add "bottom-swimming". Keys are matched in sorted order and added together, so
    /// the result does not depend on the order of `rules` or on per-launch hash seeds.
    static func expandingSynonyms(
        _ tokens: Set<String>,
        normalizedText: String,
        rules: [(key: String, values: Set<String>)] = LocalObservationVocabulary.synonyms.map { (key: $0.key, values: $0.value) }
    ) -> Set<String> {
        let matched = rules.sorted { $0.key < $1.key }.filter { rule in
            rule.values.contains { matches($0, inTokens: tokens, normalizedText: normalizedText) }
        }
        return tokens.union(matched.map(\.key))
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
    /// Coordinated colours before one marking noun ("blue and yellow stripes", "black, white
    /// or gray spots"): the marking applies to each colour.
    private static let coordinatedMarkingRegex = try! NSRegularExpression(pattern: "\\b(" + color + ")(?:\\s*,\\s*(" + color + "))?\\s*,?[ -]+(?:and|or)[ -]+(" + color + ")(?:[ -]+(?:thin|fine|broad|narrow|small|large))?[ -]+(" + marking + ")\\b", options: [.caseInsensitive])

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
        }).union(captures(coordinatedMarkingRegex, in: affirmative).flatMap { groups -> [String] in
            guard let marking = markingWords[groups[3]] else { return [] }
            return groups[0..<3].compactMap { colorWords[$0] }.map { $0 + " " + marking }
        })
        let compounds = captures(compoundRegex, in: affirmative).compactMap { pair -> String? in
            guard let first = colorWords[pair[0]], let second = colorWords[pair[1]], first != second else { return nil }
            return [first, second].sorted().joined(separator: "-") + " hue"
        }
        let contrasts = bodyContrastPatterns.compactMap { pattern, relation in
            pattern.firstMatch(in: affirmative, range: NSRange(affirmative.startIndex..., in: affirmative)) == nil ? nil : relation
        }
        return markings.union(compounds).union(contrasts)
    }

    /// A body paler at the front than at the rear (or the reverse), stated either way round.
    private static let bodyContrastPatterns: [(NSRegularExpression, String)] = {
        let front = "(?:front|fore|anterior)", rear = "(?:rear|hind|posterior)"
        let pale = "(?:pale|paler|light|lighter|whitish)", dark = "(?:dark|darker|blackish)"
        let half = "(?:\\s+(?:half|part|portion))?(?:\\s+of(?:\\s+the)?\\s+body)?\\s+(?:is\\s+)?(?:[a-z]+ly\\s+)?"
        func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) }
        return [
            (regex("\\b" + pale + "\\s+" + front + "\\b|\\b" + front + half + "(?:paler|lighter)\\b|\\b" + dark + "\\s+" + rear + "\\b|\\b" + rear + half + "darker\\b"), "paler front"),
            (regex("\\b" + pale + "\\s+" + rear + "\\b|\\b" + rear + half + "(?:paler|lighter)\\b|\\b" + dark + "\\s+" + front + "\\b|\\b" + front + half + "darker\\b"), "paler rear")
        ]
    }()
}
