import Foundation

// MARK: The diver's answers

/// Clues a diver adds after a description search, kept apart from the original description,
/// which is never edited. Each answer is the diver's own: a skipped question has no entry,
/// and "Not sure" is recorded as such, never as a trait.
struct SearchRefinement: Hashable, Codable, Sendable {
    enum Dimension: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
        case bodyShape, markings, size, habitat, behavior
    }

    enum Answer: Hashable, Codable, Sendable {
        /// The diver doesn't know. Adds nothing to the search.
        case notSure
        /// Markings only: none of the listed markings. Absence is never scored.
        case noneObserved
        /// Option keys from `RefinementQuestions.options`, sorted.
        case values([String])
        /// A measured length in the units the diver used.
        case measured(value: Double, unit: LengthUnit)
        /// A rough size, in the parser's own words.
        case sizeBand(SizeBand)
    }

    enum LengthUnit: String, Codable, CaseIterable, Sendable {
        case centimetres, metres, inches, feet
        /// The unit word the observation parser reads.
        var parserWord: String { switch self { case .centimetres: "cm"; case .metres: "m"; case .inches: "inches"; case .feet: "feet" } }
        var symbol: String { switch self { case .centimetres: "cm"; case .metres: "m"; case .inches: "in"; case .feet: "ft" } }
        func centimetres(_ value: Double) -> Double {
            switch self { case .centimetres: value; case .metres: value * 100; case .inches: value * 2.54; case .feet: value * 30.48 }
        }
    }

    enum SizeBand: String, Codable, CaseIterable, Sendable { case small, medium, large }

    var answers: [Dimension: Answer] = [:]

    var isEmpty: Bool { answers.isEmpty }
    /// Answers that can add evidence (not "Not sure" or "None of these").
    var hasEvidence: Bool {
        answers.values.contains { if case .notSure = $0 { return false }; if case .noneObserved = $0 { return false }; return true }
    }

    /// One line per answered question, in the diver's terms: "Body shape: Flat".
    var summaryLines: [String] {
        Dimension.allCases.compactMap { dimension in
            answers[dimension].map { "\(RefinementQuestions.title(dimension)): \(RefinementQuestions.describe($0, in: dimension))" }
        }
    }
}

// MARK: The questions

/// Neutral questions. Options are the same fixed list for every search, never derived from
/// the candidates, so they can't reveal an assumed species or suggest a trait as fact.
/// Every option is a word the observation parser reads as that trait (a test checks this);
/// catalogue traits it can't read from text (saddles, eye stripe, open water) aren't offered.
enum RefinementQuestions {
    struct Option: Hashable, Sendable {
        let key: String
        let label: String
        /// The words added to the search, in the observation parser's vocabulary.
        let phrase: String
    }

    static func title(_ dimension: SearchRefinement.Dimension) -> String {
        switch dimension {
        case .bodyShape: "Body shape"
        case .markings: "Markings"
        case .size: "Size"
        case .habitat: "Where it was"
        case .behavior: "What it was doing"
        }
    }

    static func question(_ dimension: SearchRefinement.Dimension) -> String {
        switch dimension {
        case .bodyShape: "What shape was its body?"
        case .markings: "Did you notice any of these markings?"
        case .size: "About how big was it?"
        case .habitat: "Where did you see it?"
        case .behavior: "What was it doing?"
        }
    }

    /// Several answers allowed (markings, places, behaviours) or one (shape, size).
    static func allowsSeveral(_ dimension: SearchRefinement.Dimension) -> Bool {
        dimension == .markings || dimension == .habitat || dimension == .behavior
    }

    static let options: [SearchRefinement.Dimension: [Option]] = [
        .bodyShape: [
            .init(key: "flat", label: "Flat, like a ray", phrase: "flat"),
            .init(key: "elongated", label: "Long and slender", phrase: "elongated"),
            .init(key: "serpentine", label: "Snake-like", phrase: "serpentine"),
            .init(key: "torpedo", label: "Torpedo-shaped", phrase: "torpedo"),
            .init(key: "oval", label: "Round or oval", phrase: "oval"),
            .init(key: "compressed", label: "Tall and thin from the side", phrase: "compressed"),
        ],
        .markings: [
            .init(key: "spots", label: "Spots", phrase: "spots"),
            .init(key: "stripes", label: "Stripes or bars", phrase: "stripes"),
            .init(key: "patches", label: "Patches or blotches", phrase: "patches"),
            .init(key: "spines", label: "Spines", phrase: "spines"),
        ],
        .habitat: [
            .init(key: "reef", label: "Coral reef", phrase: "reef"),
            .init(key: "sand", label: "Sand", phrase: "sand"),
            .init(key: "seagrass", label: "Seagrass", phrase: "seagrass"),
            .init(key: "rubble", label: "Rubble", phrase: "rubble"),
            .init(key: "wall", label: "Wall or drop-off", phrase: "wall"),
            .init(key: "wreck", label: "Wreck", phrase: "wreck"),
            .init(key: "mangrove", label: "Mangroves", phrase: "mangrove"),
            .init(key: "anemone", label: "In an anemone", phrase: "anemone"),
        ],
        .behavior: [
            .init(key: "schooling", label: "In a group or school", phrase: "schooling"),
            .init(key: "solitary", label: "Alone", phrase: "solitary"),
            .init(key: "hovering", label: "Hovering in place", phrase: "hovering"),
            .init(key: "resting", label: "Resting on the bottom", phrase: "resting"),
            .init(key: "hiding", label: "Hiding", phrase: "hiding"),
            .init(key: "burrowing", label: "Buried or burrowing", phrase: "burrowing"),
            .init(key: "feeding", label: "Feeding", phrase: "feeding"),
            .init(key: "cleaning", label: "Cleaning other animals", phrase: "cleaning"),
        ],
    ]

    static func sizeBandLabel(_ band: SearchRefinement.SizeBand) -> String {
        switch band {
        case .small: "Small (hand-sized or less)"
        case .medium: "Medium (about forearm to arm length)"
        case .large: "Large (longer than an arm)"
        }
    }

    static func describe(_ answer: SearchRefinement.Answer, in dimension: SearchRefinement.Dimension) -> String {
        switch answer {
        case .notSure: return "Not sure"
        case .noneObserved: return "None of these"
        case .values(let keys):
            let labels = options[dimension] ?? []
            return keys.map { key in labels.first { $0.key == key }?.label ?? key }.joined(separator: ", ")
        case .measured(let value, let unit): return "About \(DiveForm.format(value)) \(unit.symbol)"
        case .sizeBand(let band): return sizeBandLabel(band)
        }
    }

    /// Questions in the order to ask them. A question the description already answers comes
    /// last. Among the rest, one whose answer would split the current candidates comes first
    /// (more distinct catalogue values among them, more useful); ties keep the fixed order.
    /// Only the order uses the candidates: every question and option stays the same.
    static func order(observation: ParsedObservation, candidates: [Species]) -> [SearchRefinement.Dimension] {
        let top = Array(candidates.prefix(5))
        func covered(_ dimension: SearchRefinement.Dimension) -> Bool {
            switch dimension {
            case .bodyShape: !observation.bodyShapes.isEmpty
            case .markings: !observation.markings.isEmpty
            case .size: observation.approximateSizeCentimeters != nil
            case .habitat: !observation.habitats.isEmpty
            case .behavior: !observation.behaviors.isEmpty
            }
        }
        func spread(_ dimension: SearchRefinement.Dimension) -> Int {
            guard top.count > 1 else { return 0 }
            let signatures: [String] = top.map { species in
                switch dimension {
                case .bodyShape: species.bodyShapes.sorted().joined(separator: "|")
                case .markings: species.markings.sorted().joined(separator: "|")
                case .habitat: species.habitats.sorted().joined(separator: "|")
                case .behavior: species.behaviors.sorted().joined(separator: "|")
                case .size: sizeClass(species.maximumSizeCentimeters)
                }
            }
            // Unknown catalogue values tell the diver nothing, so they don't count as a split.
            return Set(signatures.filter { !$0.isEmpty }).count
        }
        return SearchRefinement.Dimension.allCases.enumerated().sorted { a, b in
            let (ca, cb) = (covered(a.element), covered(b.element))
            if ca != cb { return !ca }
            let (sa, sb) = (spread(a.element), spread(b.element))
            if sa != sb { return sa > sb }
            return a.offset < b.offset
        }.map(\.element)
    }

    private static func sizeClass(_ maximum: Double?) -> String { maximum.map { sizeBand(forCentimetres: $0).rawValue } ?? "" }

    /// The rough size a length falls in, matching the parser's own small / medium / large.
    static func sizeBand(forCentimetres size: Double) -> SearchRefinement.SizeBand {
        size <= 15 ? .small : size <= 60 ? .medium : .large
    }
}

// MARK: Combining with the description

/// The text a refined search runs on, and what happened to each answer. The original is
/// first and unchanged; an answer the description already gives adds nothing, so no clue is
/// counted twice; an answer that disagrees with the description is kept with it.
struct RefinedSearchText: Equatable, Sendable {
    let original: String
    let searchText: String
    /// Phrases appended to the original, in question order.
    let added: [String]
    /// Answers the description already contained; not added again.
    let alreadyInDescription: [SearchRefinement.Dimension]
    /// Questions where the answer and the description disagree; both are kept.
    let disagreements: [SearchRefinement.Dimension]

    static func compose(original: String, refinement: SearchRefinement?, parser: some ObservationParsing = LocalObservationParser()) async -> RefinedSearchText {
        guard let refinement, refinement.hasEvidence else {
            return RefinedSearchText(original: original, searchText: original, added: [], alreadyInDescription: [], disagreements: [])
        }
        let described = await parser.parse(original)
        var added: [String] = [], already: [SearchRefinement.Dimension] = [], disagree: [SearchRefinement.Dimension] = []
        for dimension in SearchRefinement.Dimension.allCases {
            guard let answer = refinement.answers[dimension] else { continue }
            switch answer {
            case .notSure, .noneObserved:
                continue
            case .values(let keys):
                let phrases = keys.compactMap { key in RefinementQuestions.options[dimension]?.first { $0.key == key }?.phrase }
                var fresh: [String] = []
                for phrase in phrases {
                    let parsed = await parser.parse(phrase)
                    let (mine, theirs) = (traits(parsed, dimension), traits(described, dimension))
                    if !mine.isEmpty, mine.isSubset(of: theirs) { continue }  // already said: never counted twice
                    fresh.append(phrase)
                }
                if fresh.count < phrases.count { already.append(dimension) }
                if dimension == .bodyShape, !fresh.isEmpty, !described.bodyShapes.isEmpty { disagree.append(dimension) }
                added += fresh
            case .measured(let value, let unit):
                let phrase = "about \(DiveForm.format(value)) \(unit.parserWord) long"
                if let size = described.approximateSizeCentimeters {
                    // Within 10%: the same size, already said. Otherwise both stay; the
                    // description's measurement comes first, so the parser uses it.
                    if abs(unit.centimetres(value) - size) <= size * 0.1 { already.append(dimension); continue }
                    disagree.append(dimension)
                }
                added.append(phrase)
            case .sizeBand(let band):
                if let size = described.approximateSizeCentimeters {
                    // The same rough size is already said; a different one is kept and noted.
                    // The description's size stays the one the parser measures with.
                    if RefinementQuestions.sizeBand(forCentimetres: size) == band { already.append(dimension); continue }
                    disagree.append(dimension)
                }
                added.append(band.rawValue)
            }
        }
        let searchText = added.isEmpty ? original : original + ". " + added.joined(separator: ". ") + "."
        return RefinedSearchText(original: original, searchText: searchText, added: added, alreadyInDescription: already, disagreements: disagree)
    }

    private static func traits(_ observation: ParsedObservation, _ dimension: SearchRefinement.Dimension) -> Set<String> {
        switch dimension {
        case .bodyShape: observation.bodyShapes
        case .markings: observation.markings
        case .habitat: observation.habitats
        case .behavior: observation.behaviors
        case .size: []
        }
    }
}
