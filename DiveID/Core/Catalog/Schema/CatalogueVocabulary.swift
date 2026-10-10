import Foundation

/// Controlled terms shared by bundled catalogue validation and description search.
enum CatalogueVocabulary {
    static let colors: Set<String> = [
        "black", "blue", "brown", "gray", "green", "olive", "orange", "red", "silver", "white", "yellow"
    ]
    static let markings: Set<String> = [
        "barbels", "beak", "eye stripe", "fin edge", "patches", "saddles", "shell", "spines", "spots", "stripes", "tail", "teeth"
    ]
    static let bodyShapes: Set<String> = [
        "leaflike", "compressed", "disk", "elongated", "flat", "oval", "pointed", "robust", "round", "serpentine", "torpedo"
    ]
    static let habitats: Set<String> = [
        "anemone", "deep", "lagoon", "mangrove", "open water", "reef", "rubble", "sand", "seagrass", "shallow", "surface", "wall", "wreck"
    ]
    static let categories: Set<String> = [
        "crustacean", "eel", "fish", "mollusk", "octopus", "ray", "seahorse", "shark", "squid", "turtle"
    ]
    static let behaviors: Set<String> = [
        "anemone association", "bottom-swimming", "burrowing", "cleaning", "feeding", "grazing", "hiding", "hovering", "open-water cruising", "resting", "schooling", "solitary", "swimming"
    ]
    static let regions: Set<String> = [
        "aruba", "atlantic", "bahamas", "belize", "bermuda", "bonaire", "british virgin islands", "caribbean", "cayman islands", "cozumel", "curaçao", "curacao", "dominican republic", "fiji", "florida", "gulf of mexico", "hawaii", "indian", "indo-pacific", "jamaica", "pacific", "puerto rico", "turks and caicos", "us virgin islands", "western atlantic"
    ]
}

/// Scoped morphology: fin height, outline and filaments are independent of spines
/// and of body outline. Canonical tokens are shared by parsing and BM25.
enum MorphologyVocabulary {
    static let patterns: [(String, String)] = [
        ("leaflike", #"\b(?:leaf(?: like| shaped|like)|leaflike)\s+(?:(?!(?:dorsal|fin|tail)\b)[a-z]+\s+)?(?:body|fish|animal)\b|\bbody\s+(?:is\s+)?(?:leaflike|leaf like|leaf shaped|shaped like a leaf)\b"#),
        ("tall dorsal fin", #"\b(?:tall|high|elevated|raised)\s+(?:first |1st |front |anterior )?dorsal(?: fin)?\b|\bdorsal fin\s+(?:is\s+)?(?:tall|high|elevated|raised)\b"#),
        ("sail shaped dorsal fin", #"\b(?:sail like|sail shaped|saillike)\s+dorsal fin\b|\bdorsal fin\s+(?:is\s+)?(?:sail like|sail shaped|shaped like a sail)\b"#),
        ("filamentous dorsal fin", #"\b(?:filamentous|thread like|threadlike)\s+(?:first )?dorsal fin\b|\bdorsal (?:fin )?(?:filament|streamer)\b"#)
    ]

    static func concepts(in text: String) -> Set<String> {
        let normalized = LocalObservationParser.normalize(LocalObservationParser.affirmativeEvidence(in: text))
        return Set(patterns.compactMap { concept, pattern in
            normalized.range(of: pattern, options: .regularExpression) == nil ? nil : concept
        })
    }

    static func scopedText(_ text: String) -> String {
        var normalized = LocalObservationParser.normalize(text)
        for (concept, pattern) in patterns {
            if concept == "leaflike" {
                // Preserve the subject and its modifiers: morphology normalization
                // must not erase "fish" or habitat words from retrieval.
                let regex = try! NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)).reversed() {
                    guard let range = Range(match.range, in: normalized) else { continue }
                    let phrase = String(normalized[range])
                        .replacingOccurrences(of: #"leaf(?: like| shaped|like)|shaped like a leaf"#,
                                              with: "leaflike", options: .regularExpression)
                    normalized.replaceSubrange(range, with: phrase)
                }
            } else {
                normalized = normalized.replacingOccurrences(of: pattern,
                    with: concept.replacingOccurrences(of: " ", with: ""), options: .regularExpression)
            }
        }
        return normalized
    }
}
