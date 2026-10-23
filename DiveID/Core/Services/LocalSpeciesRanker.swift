import Foundation

protocol SpeciesRanking: Sendable {
    func rank(input: SpeciesRankingInput) async throws -> [RankedLocalSpecies]
}

/// Complete input to ranking. A nil retrieval signal deliberately identifies the
/// independently testable structured baseline rather than an unknown score.
struct SpeciesRankingInput: Sendable {
    let description: String
    let observation: ParsedObservation
    let candidates: [SpeciesRankingCandidate]
    /// The diver's optional "where are you diving?" choice. It boosts ordering only;
    /// it is not evidence from the description and never excludes a species.
    var preferredRegions: Set<String> = []
    /// Normalized aliases that name a group rather than one species in the searched pack
    /// (see `OfflineIdentificationPack.groupNames`). They never count as an exact name.
    var groupNames: Set<String> = []
}

struct SpeciesRankingCandidate: Sendable {
    let speciesID: UUID
    let profile: LocalSpeciesProfile
    let retrieval: SpeciesRetrievalSignal?
}

struct SpeciesRetrievalSignal: Sendable, Equatable {
    let source: RetrievedSpeciesCandidate.Evidence
    let scoreKind: RetrievalScoreKind
    let score: Double
    let rank: Int
    let evidence: [String]
}

extension SpeciesRanking {
    /// Compatibility entry point for the structured engine and its direct tests.
    func rank(observation: ParsedObservation, profiles: [LocalSpeciesProfile]) async throws -> [RankedLocalSpecies] {
        try await rank(input: SpeciesRankingInput(
            description: observation.normalizedText,
            observation: observation,
            candidates: profiles.map { SpeciesRankingCandidate(speciesID: $0.id, profile: $0, retrieval: nil) }
        ))
    }
}

struct RankedLocalSpecies: Sendable {
    let profile: LocalSpeciesProfile
    let rawScore: Double
    let retrievalRelevance: Double?
    let orderingScore: Double
    let score: Double
    let matchedClues: [String]
    let conflictingClues: [String]
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
    let informationLevel: ObservationInformationLevel
}

extension RankedLocalSpecies {
    init(profile: LocalSpeciesProfile, score: Double, matchedClues: [String], conflictingClues: [String], matchedAppearanceVariant: SpeciesAppearanceVariant?, informationLevel: ObservationInformationLevel) {
        self.profile = profile
        self.rawScore = score
        self.retrievalRelevance = nil
        self.orderingScore = score
        self.score = score
        self.matchedClues = matchedClues
        self.conflictingClues = conflictingClues
        self.matchedAppearanceVariant = matchedAppearanceVariant
        self.informationLevel = informationLevel
    }

}

struct LocalRankingWeights: Sendable {
    let exactName = 20.0, category = 6.0, region = 5.0, habitat = 4.0, marking = 4.0, color = 3.0, bodyShape = 3.0, size = 3.0, depth = 2.0, behavior = 2.0, keyword = 1.0, waterConflict = -10.0, sizeConflict = -4.0, habitatConflict = -3.0, preferredRegion = 3.0, outOfRange = -3.0
    let appearanceRelationship = 2.0, tailShape = 2.0, headAndMouth = 2.0, finAndSpine = 2.0
    let threshold = 4.0, maximumRawScore = 42.0
    /// Raw cosine a semantic-only candidate needs for provisional admission, and the zero
    /// point of its ordering contribution. Calibrated on the Global score distribution
    /// (Docs/HybridRankingContract.md, "Semantic calibration").
    let semanticAdmissionCosine = 0.30
}

private struct RawRankedCandidate {
    let profile: LocalSpeciesProfile
    let rawScore: Double
    let matchedClues: [String]
    let conflictingClues: [String]
    let matchedAppearanceVariant: SpeciesAppearanceVariant?
    let informationLevel: ObservationInformationLevel
    let retrievalRelevance: Double?
    let orderingScore: Double
    let hasBiologicalEvidence: Bool
}

struct LocalSpeciesRanker: SpeciesRanking {
    let weights: LocalRankingWeights
    private let regionResolver = RegionCompatibilityResolver()
    init(weights: LocalRankingWeights = LocalRankingWeights()) { self.weights = weights }

    func rank(input: SpeciesRankingInput) async throws -> [RankedLocalSpecies] {
        try Task.checkCancellation()
        let observation = input.observation
        // A decisive subject contradiction cannot be outweighed by generic clues,
        // exact-name overlap, or provisional semantic retrieval eligibility.
        guard observation.domainContradiction == nil else { return [] }
        let observationInformation = Self.informationLevel(observation)
        let meaningfulTermCount = Self.meaningfulTerms(input.description).count
        var seen = Set<UUID>()
        let rawCandidates = input.candidates.compactMap { candidate -> RawRankedCandidate? in
            let profile = candidate.profile
            guard candidate.speciesID == profile.id, seen.insert(candidate.speciesID).inserted else { return nil }
            var score = 0.0
            var matched: [String] = []
            var conflicts: [String] = []
            // A group name in this pack ("Surgeonfish", "Grouper") helps retrieval and partial
            // identity matching, but does not name one species. That includes a one-word common
            // name that other records' names end in ("Angelfish"). Scientific names always count.
            let commonName = LocalObservationParser.normalize(profile.commonName)
            let isGroupCommonName = !commonName.contains(" ") && input.groupNames.contains(commonName)
            let nameTerms = ([profile.scientificName] + (isGroupCommonName ? [] : [profile.commonName])
                             + profile.aliases.filter { !input.groupNames.contains(LocalObservationParser.normalize($0)) })
                .map(LocalObservationParser.normalize)
            let hasExactName = nameTerms.contains {
                LocalObservationParser.matches($0, inTokens: observation.tokens, normalizedText: observation.normalizedText)
                    && Self.namesSubject($0, in: input.description)
            }
            let retrievalRelevance = candidate.retrieval.map(normalizedRelevance)
            let provisionalSemantic = candidate.retrieval?.scoreKind == .cosineSimilarity
                && (candidate.retrieval?.score ?? -1) >= weights.semanticAdmissionCosine && meaningfulTermCount >= 3
            guard observationInformation != .insufficient || hasExactName || provisionalSemantic else { return nil }
            let informationLevel: ObservationInformationLevel = hasExactName ? .sufficient
                : (provisionalSemantic && observationInformation == .insufficient ? .limited : observationInformation)
            if hasExactName { score += weights.exactName; matched.append(profile.commonName) }
            add(observation.categories, profile.categories, weights.category, &score, &matched)
            let described = regionCompatibility(observedRegions: observation.regions, supportedRegions: Set(profile.regions))
            switch described {
            case .compatible:
                score += weights.region
                matched.append("geographic range")
            case .conflicting, .unspecified:
                // Location is never evidence against a species: an out-of-range
                // sighting only lowers ordering below, so rare strays still match.
                break
            }
            add(observation.habitats, profile.habitats, weights.habitat, &score, &matched)
            add(observation.markings, profile.markings, weights.marking, &score, &matched)
            addColors(observation, profile.colors, &score, &matched)
            let sourceAppearance = ([profile.summary] + profile.distinguishingFeatures).joined(separator: " | ")
            let patterned = observation.appearanceRelationships.intersection(AppearanceEvidenceVocabulary.appearanceRelationships(in: sourceAppearance))
            if !patterned.isEmpty {
                // One bounded relation group; aliases and repeated source prose
                // cannot multiply the evidence. Missing relations stay neutral.
                score += weights.appearanceRelationship
                matched.append(contentsOf: patterned.sorted())
            }
            // Variants are alternatives (a fish is juvenile or adult, male or female), so only
            // the best compatible one counts, and only for clues the main profile has not
            // already credited. A named life stage excludes other stages; no stage named
            // leaves every variant possible.
            let namedStages = Self.namedLifeStages(observation.tokens)
            let mainColorGroups = colorHits(observation, profile.colors)
            var bestVariant: SpeciesAppearanceVariant? = nil
            var bestVariantScore = 0.0
            for variant in profile.appearanceVariants where namedStages.isEmpty || namedStages.contains(variant.lifeStage) {
                var variantScore = 0.0; var variantHits: [String] = []
                let colorGroups = colorHits(observation, variant.colors).filter { group in !mainColorGroups.contains { $0.group == group.group } }
                variantScore += Double(colorGroups.count) * weights.color
                add(observation.markings.subtracting(profile.markings.map { $0.lowercased() }), variant.markings, weights.marking, &variantScore, &variantHits)
                add(observation.bodyShapes.subtracting(profile.bodyShapes.map { $0.lowercased() }), variant.bodyShapes, weights.bodyShape, &variantScore, &variantHits)
                if variantScore > bestVariantScore { bestVariantScore = variantScore; bestVariant = variant }
            }
            if let bestVariant, bestVariantScore >= weights.color { score += min(bestVariantScore, 6); matched.append("\(bestVariant.lifeStage.rawValue) appearance") }
            add(observation.bodyShapes, profile.bodyShapes, weights.bodyShape, &score, &matched)
            add(observation.behaviors, profile.behaviors, weights.behavior, &score, &matched)
            add(observation.tokens, profile.keywords, weights.keyword, &score, &matched)
            // Partial identity words (for example an animal-group noun) are
            // available in both engines, even when a draft's keyword list is
            // empty. They are weak identity evidence, not an exact-name match
            // or inferred anatomy. Do not count trait words a second time.
            if !hasExactName {
                let identityWords = Set(([profile.commonName, profile.scientificName] + profile.aliases)
                    .flatMap { LocalObservationParser.normalize($0).split(separator: " ").map(String.init) }
                    .map(LocalObservationParser.singular))
                    .subtracting(Self.nonIdentityTerms)
                    .subtracting(profile.keywords.flatMap { LocalObservationParser.normalize($0).split(separator: " ").map(String.init) }.map(LocalObservationParser.singular))
                let hits = observation.tokens.intersection(identityWords).filter { $0.count > 2 }.sorted()
                score += Double(hits.count) * weights.keyword
                matched.append(contentsOf: hits.map { "identity term: " + $0 })
            }
            addVisibleClue(profile.tailShape.map { [$0] } ?? [], label: "tail shape", weight: weights.tailShape, observation: observation, legacyTerms: profile.markings + profile.bodyShapes + profile.keywords, score: &score, matched: &matched)
            addVisibleClue(profile.mouthAndHeadShape, label: "head and mouth shape", weight: weights.headAndMouth, observation: observation, legacyTerms: profile.markings + profile.bodyShapes + profile.keywords, score: &score, matched: &matched)
            let finConcepts = profile.finAndSpineClues.reduce(into: Set<String>()) { $0.formUnion(MorphologyVocabulary.concepts(in: $1)) }
                .subtracting(["leaflike"])
            let finHits = finConcepts.intersection(observation.tokens)
            // One fin evidence group, regardless of the number of aliases stored.
            if !finHits.isEmpty {
                score += weights.finAndSpine
                matched.append(contentsOf: finHits.sorted())
            }
            addVisibleClue(profile.finAndSpineClues.filter { MorphologyVocabulary.concepts(in: $0).isEmpty && finHits.isEmpty }, label: "fin and spine clues", weight: weights.finAndSpine, observation: observation, legacyTerms: profile.markings + profile.bodyShapes + profile.keywords, score: &score, matched: &matched)
            // A described size is a length. A width-type measurement (disc or carapace width)
            // is never compared with it. A maximum-only record is compatible up to the same
            // 1.5 × tolerance and has no lower bound; no minimum is invented.
            let measuresWidth = profile.measurements?.type.isWidth ?? false
            let canonicalMinimum = profile.measurements?.typicalObservedMinimumCentimeters ?? profile.minimumSizeCentimeters
            let canonicalMaximum = profile.measurements?.typicalObservedMaximumCentimeters ?? profile.measurements?.maximumRecordedCentimeters ?? profile.maximumSizeCentimeters
            if let size = observation.approximateSizeCentimeters, !measuresWidth, let max = canonicalMaximum {
                let lowest = canonicalMinimum.map { $0 * 0.5 } ?? 0
                if (lowest...(max * 1.5)) ~= size { score += weights.size; matched.append("compatible size") } else { score += weights.sizeConflict; conflicts.append("described size") }
            }
            if let depth = observation.approximateDepthMeters, let min = profile.minimumDepthMeters, let max = profile.maximumDepthMeters, (min - 3)...(max + 5) ~= depth { score += weights.depth; matched.append("compatible depth") }
            if observation.categories.contains("fish"), profile.categories.contains("turtle") || profile.categories.contains("ray") { score += weights.waterConflict; conflicts.append("animal group") }
            if !observation.habitats.isEmpty, !profile.habitats.isEmpty, observation.habitats.intersection(Set(profile.habitats)).isEmpty, score > 0 { score += weights.habitatConflict; conflicts.append("habitat") }
            // Retrieval is normalized by its declared scale: cosine maps the admission floor..1
            // to [0, 1], while BM25 uses a saturating transform s/(s+3). This
            // avoids adding incompatible raw values. Semantic retrieval can grant
            // provisional eligibility, but never upgrades confidence by itself.
            let hasBiologicalEvidence = score >= weights.threshold || hasExactName
            guard hasBiologicalEvidence || provisionalSemantic else { return nil }
            let relevanceContribution = (retrievalRelevance ?? 0) * 8
            let preferredRegionBoost = isInPreferredRegion(profile, input.preferredRegions) ? weights.preferredRegion : 0
            let orderingScore = score + relevanceContribution + occurrenceWeight(profile.regionalOccurrence) + preferredRegionBoost
            guard orderingScore > 0 else { return nil }
            // Applied after eligibility, so the out-of-range penalty reorders but never removes.
            let rangeAdjustedOrdering = orderingScore + (described == .conflicting ? weights.outOfRange : 0)
            if candidate.retrieval?.source == .semantic { matched.append("catalogue description similarity") }
            return RawRankedCandidate(profile: profile, rawScore: score, matchedClues: unique(matched), conflictingClues: unique(conflicts), matchedAppearanceVariant: bestVariant, informationLevel: informationLevel, retrievalRelevance: retrievalRelevance, orderingScore: rangeAdjustedOrdering, hasBiologicalEvidence: hasBiologicalEvidence)
        }
        return rawCandidates.sorted { a, b in
            // Similarity alone never outranks a candidate with biological evidence. Without
            // a cosine signal every candidate has evidence, so this changes no BM25 order.
            if a.hasBiologicalEvidence != b.hasBiologicalEvidence { return a.hasBiologicalEvidence }
            if a.orderingScore != b.orderingScore { return a.orderingScore > b.orderingScore }
            if a.profile.commonName != b.profile.commonName { return a.profile.commonName < b.profile.commonName }
            return a.profile.id.uuidString < b.profile.id.uuidString
        }.prefix(10).map { candidate in
            // Confidence remains structured evidence, not retrieval probability.
            var normalized = max(0, min(1, candidate.rawScore / weights.maximumRawScore))
            if candidate.informationLevel == .limited { normalized = min(normalized, 0.64) }
            return RankedLocalSpecies(profile: candidate.profile, rawScore: candidate.rawScore, retrievalRelevance: candidate.retrievalRelevance, orderingScore: candidate.orderingScore, score: normalized, matchedClues: candidate.matchedClues, conflictingClues: candidate.conflictingClues, matchedAppearanceVariant: candidate.matchedAppearanceVariant, informationLevel: candidate.informationLevel)
        }
    }

    private static let nonIdentityTerms: Set<String> = {
        let traits = CatalogueVocabulary.colors.union(CatalogueVocabulary.markings)
            .union(CatalogueVocabulary.bodyShapes).union(CatalogueVocabulary.habitats)
            .union(CatalogueVocabulary.categories).union(CatalogueVocabulary.behaviors)
            .union(LocalObservationVocabulary.synonyms.values.flatMap { $0 })
        return Set(traits.flatMap { LocalObservationParser.normalize($0).split(separator: " ").map(String.init) }
            .map(LocalObservationParser.singular)).union(LocalObservationVocabulary.stopWords)
    }()

    private func normalizedRelevance(_ signal: SpeciesRetrievalSignal) -> Double {
        switch signal.scoreKind {
        // Zero at the admission floor, so a barely admitted semantic hit adds almost nothing
        // to ordering; most unrelated species already score near the floor.
        case .cosineSimilarity:
            let floor = weights.semanticAdmissionCosine
            return max(0, min(1, (signal.score - floor) / (1 - floor)))
        case .bm25: return signal.score > 0 ? min(1, signal.score / (signal.score + 3)) : 0
        }
    }

    private static func meaningfulTerms(_ description: String) -> Set<String> {
        let ignored: Set<String> = ["a", "an", "and", "animal", "fish", "in", "is", "it", "of", "on", "the", "to", "with"]
        return Set(description.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 && !ignored.contains($0) })
    }

    func regionCompatibility(observedRegions: Set<String>, supportedRegions: Set<String>) -> RegionCompatibility {
        regionResolver.compatibility(observedRegions: observedRegions, supportedRegions: supportedRegions)
    }

    private func isInPreferredRegion(_ profile: LocalSpeciesProfile, _ preferred: Set<String>) -> Bool {
        preferred.contains { regionCompatibility(observedRegions: [$0], supportedRegions: Set(profile.regions)) == .compatible }
    }

    private func occurrenceWeight(_ status: RegionalOccurrenceStatus) -> Double { switch status { case .common: 3; case .regular: 2; case .introduced: 1; case .unknown, .occasional, .seasonal: 0; case .rare: -3 } }

    private static func informationLevel(_ observation: ParsedObservation) -> ObservationInformationLevel {
        // Each boolean is an independent semantic clue group. Expanded synonyms stay
        // inside their source group and therefore never increase the evidence count.
        let hasFinMorphology = !observation.tokens.isDisjoint(with: Set(MorphologyVocabulary.patterns.dropFirst().map { $0.0 }))
        let groups = [
            hasFinMorphology,
            !observation.categories.isEmpty,
            !observation.colors.isEmpty,
            !observation.markings.isEmpty,
            !observation.bodyShapes.isEmpty,
            !observation.habitats.isEmpty,
            !observation.behaviors.isEmpty,
            !observation.regions.isEmpty,
            observation.approximateSizeCentimeters != nil,
            observation.approximateDepthMeters != nil
        ]
        let count = groups.filter { $0 }.count
        if count >= 3 { return .sufficient }
        // Naming a specific animal group ("shark", "rays", "octopus") is enough to list
        // that group's species with limited confidence. "Fish" alone is too broad.
        if !observation.categories.subtracting(["fish"]).isEmpty { return .limited }

        // Category, color, and approximate size are broad clues. Two of those alone
        // (for example, "dark fish" or "small fish") are still not identifying.
        let hasDistinctiveGroup = hasFinMorphology || !observation.markings.isEmpty
            || !observation.bodyShapes.isEmpty
            || !observation.habitats.isEmpty
            || !observation.behaviors.isEmpty
            || !observation.regions.isEmpty
            || observation.approximateDepthMeters != nil
        if count >= 2, hasDistinctiveGroup { return .limited }
        return .insufficient
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Each observed colour group supported by `colors`, with the matching colours.
    private func colorHits(_ observation: ParsedObservation, _ colors: [String]) -> [(group: Set<String>, hits: Set<String>)] {
        let groups = observation.colorEvidenceGroups.isEmpty ? observation.colors.sorted().map { Set([$0]) } : observation.colorEvidenceGroups
        let supported = Set(colors.map { $0.lowercased() })
        return groups.compactMap { group in
            let hits = group.intersection(supported)
            return hits.isEmpty ? nil : (group, hits)
        }
    }

    private func addColors(_ observation: ParsedObservation, _ colors: [String], _ score: inout Double, _ matched: inout [String]) {
        for (_, hits) in colorHits(observation, colors) { score += weights.color; matched.append(contentsOf: hits.sorted()) }
    }

    /// False when every occurrence of the name is the tail of a hyphenated compound, so
    /// "red-orange anemonefish" does not name the Orange anemonefish and "blue-lined
    /// surgeonfish" does not name the Lined surgeonfish.
    static func namesSubject(_ normalizedName: String, in description: String) -> Bool {
        let words = normalizedName.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return false }
        let text = description.lowercased()
        let pattern = "(?<![a-z0-9])" + words.joined(separator: "[\\s\\-–/]+") + "s?(?![a-z0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return true }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // A name the regex cannot find verbatim (for example matched through a singular
        // token) is left to the token match.
        guard !matches.isEmpty else { return true }
        return matches.contains { match in
            guard let range = Range(match.range, in: text), range.lowerBound > text.startIndex else { return true }
            let before = text[text.index(before: range.lowerBound)]
            guard before == "-" || before == "–" else { return true }
            let previous = text[..<text.index(before: range.lowerBound)].last
            return !(previous?.isLetter ?? false || previous?.isNumber ?? false)
        }
    }

    /// Life stages or sexes the description names, mapped to the variant stages they allow.
    static func namedLifeStages(_ tokens: Set<String>) -> Set<SpeciesLifeStage> {
        var stages = Set<SpeciesLifeStage>()
        if !tokens.isDisjoint(with: ["juvenile", "juveniles", "young"]) { stages.insert(.juvenile) }
        if !tokens.isDisjoint(with: ["male", "males"]) { stages.formUnion([.male, .terminalPhase]) }
        if !tokens.isDisjoint(with: ["female", "females"]) { stages.formUnion([.female, .initialPhase]) }
        if !tokens.isDisjoint(with: ["adult", "adults"]) { stages.formUnion([.adult, .male, .female, .initialPhase, .terminalPhase]) }
        return stages
    }

    private func add(_ observed: Set<String>, _ profile: [String], _ weight: Double, _ score: inout Double, _ matched: inout [String]) {
        let hits = observed.intersection(Set(profile.map { $0.lowercased() })).sorted()
        score += Double(hits.count) * weight
        matched.append(contentsOf: hits)
    }

    private func addVisibleClue(_ clues: [String], label: String, weight: Double, observation: ParsedObservation, legacyTerms: [String], score: inout Double, matched: inout [String]) {
        let matchedLegacy = legacyTerms.map(LocalObservationParser.normalize).filter {
            LocalObservationParser.matches($0, inTokens: observation.tokens, normalizedText: observation.normalizedText)
        }
        let hasNewMatch = clues
            .map(LocalObservationParser.normalize)
            .filter { clue in
                let clueTokens = Set(clue.split(separator: " ").map(String.init).map(LocalObservationParser.singular))
                return !matchedLegacy.contains { legacy in
                    let legacyTokens = Set(legacy.split(separator: " ").map(String.init).map(LocalObservationParser.singular))
                    return !clueTokens.isDisjoint(with: legacyTokens)
                }
            }
            .contains { LocalObservationParser.matches($0, inTokens: observation.tokens, normalizedText: observation.normalizedText) }
        if hasNewMatch { score += weight; matched.append(label) }
    }
}
