import XCTest
@testable import DiveID

/// Exact-name credit for group names, appearance-variant scoring and the appearance
/// relationships they rely on. Synthetic profiles isolate the rules; they are not
/// species facts.
final class RankingNameAndVariantTests: XCTestCase {
    private var seed: LocalSpeciesProfile!

    override func setUp() async throws {
        seed = try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource, access: .experimentalDevelopment)
            .loadPack(id: .caribbean).profiles[0]
    }

    private func profile(_ name: String, scientificName: String? = nil, aliases: [String] = [], colors: [String] = [], markings: [String] = [],
                         variants: [[String: Any]] = [], prose: String = "Synthetic fixture.") throws -> LocalSpeciesProfile {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as? [String: Any])
        object["id"] = UUID().uuidString
        object["commonName"] = name
        object["scientificName"] = scientificName ?? "Synthetica " + name.lowercased().replacingOccurrences(of: " ", with: "")
        object["aliases"] = aliases
        object["keywords"] = []
        object["categories"] = ["fish"]
        object["habitats"] = ["reef"]
        object["behaviors"] = []
        object["bodyShapes"] = []
        object["colors"] = colors
        object["markings"] = markings
        object["summary"] = prose
        object["distinguishingFeatures"] = [prose]
        object["appearanceVariants"] = variants
        return try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func variant(_ stage: String, colors: [String], markings: [String] = []) -> [String: Any] {
        ["id": stage, "lifeStage": stage, "colors": colors, "markings": markings, "bodyShapes": [], "description": "\(stage) fixture", "distinguishingFeatures": []]
    }

    private func rank(_ description: String, _ profiles: [LocalSpeciesProfile]) async throws -> [UUID: RankedLocalSpecies] {
        let observation = await LocalObservationParser().parse(description)
        let input = SpeciesRankingInput(description: description, observation: observation,
                                        candidates: profiles.map { SpeciesRankingCandidate(speciesID: $0.id, profile: $0, retrieval: nil) },
                                        groupNames: OfflineIdentificationPack.groupNames(in: profiles))
        return Dictionary(uniqueKeysWithValues: try await LocalSpeciesRanker().rank(input: input).map { ($0.profile.id, $0) })
    }

    // MARK: Group names

    func testGroupNamesAreHeadNounsAndSharedAliases() throws {
        let profiles = [try profile("Twospot surgeonfish", aliases: ["Surgeonfish", "Coral trout"]),
                        try profile("Lined surgeonfish", aliases: ["Coral trout", "Pyjama tang"]),
                        try profile("Hogfish")]
        XCTAssertEqual(OfflineIdentificationPack.groupNames(in: profiles), ["surgeonfish", "coral trout"])
    }

    func testAGenericGroupAliasIsNotAnExactName() async throws {
        let generic = try profile("Twospot surgeonfish", aliases: ["Surgeonfish"])
        let other = try profile("Lined surgeonfish")
        // A group word alone is not an exact name: both members come back on the group alone,
        // as limited information, with neither ahead on identity.
        let bare = try await rank("Surgeonfish on the reef", [generic, other])
        let member = try XCTUnwrap(bare[generic.id])
        XCTAssertFalse(member.matchedClues.contains(generic.commonName))
        XCTAssertEqual(member.informationLevel, .limited)
        XCTAssertLessThanOrEqual(member.score, LocalRankingWeights.limitedConfidenceCap)
        XCTAssertEqual(member.rawScore, bare[other.id]?.rawScore)
        let ranked = try await rank("Blue surgeonfish on the reef", [generic, other])
        let entry = try XCTUnwrap(ranked[generic.id])
        XCTAssertFalse(entry.matchedClues.contains(generic.commonName))
        // Both carry the group word in their names, so neither is ahead on identity.
        XCTAssertEqual(entry.rawScore, ranked[other.id]?.rawScore)
    }

    func testANamedGroupIsEvidenceForItsMembersOnly() async throws {
        let parrot = try profile("Stoplight parrotfish", colors: ["red"])
        let otherParrot = try profile("Queen parrotfish", colors: ["blue"])
        let tang = try profile("Atlantic blue tang", colors: ["blue"])
        let surgeon = try profile("Lined surgeonfish", colors: ["blue"])
        let wrasse = try profile("Bird wrasse", colors: ["red"])
        let all = [parrot, otherParrot, tang, surgeon, wrasse]
        // Only colours, which alone are too little information: the group admits its members.
        let parrotfish = try await rank("Heavy reddish parrotfish", all)
        XCTAssertEqual(Set(parrotfish.keys), [parrot.id, otherParrot.id])
        XCTAssertTrue(try XCTUnwrap(parrotfish[parrot.id]).matchedClues.contains("group: parrotfish"))
        XCTAssertGreaterThan(try XCTUnwrap(parrotfish[parrot.id]).rawScore, try XCTUnwrap(parrotfish[otherParrot.id]).rawScore)
        // Tangs are surgeonfishes.
        let surgeonfish = try await rank("Blue surgeonfish", all)
        XCTAssertEqual(Set(surgeonfish.keys), [tang.id, surgeon.id])
        // "Fish" is a generic word, never a group, so a vague description still abstains.
        let vague = try await rank("A fish moved past me.", all)
        XCTAssertTrue(vague.isEmpty)
    }

    func testATraitPlusFishAliasIsNotAName() async throws {
        let tusk = try profile("Blue tuskfish", aliases: ["Blue-fish", "Blue groper"])
        let tang = try profile("Atlantic blue tang", colors: ["blue"])
        let ranked = try await rank("Oval blue fish with a spine beside its tail", [tusk, tang])
        XCTAssertFalse(ranked.values.contains { $0.matchedClues.contains(tusk.commonName) }, "'Blue-fish' is a description, not a name")
        // A distinctive alias still names the species.
        let named = try await rank("Blue groper on the reef", [tusk, tang])
        XCTAssertTrue(try XCTUnwrap(named[tusk.id]).matchedClues.contains(tusk.commonName))
        XCTAssertFalse(LocalSpeciesRanker.isTraitPlusFish("green sea turtle"))
        XCTAssertFalse(LocalSpeciesRanker.isTraitPlusFish("spotted ray"))
    }

    func testAGenuineSpeciesNameKeepsExactCredit() async throws {
        let target = try profile("Twospot surgeonfish", scientificName: "Synthetica bipunctata", aliases: ["Surgeonfish", "Gendarmefish"])
        let other = try profile("Lined surgeonfish")
        for query in ["Twospot surgeonfish on the reef", "Synthetica bipunctata on the reef", "Gendarmefish on the reef"] {
            let ranked = try await rank(query, [target, other])
            let entry = try XCTUnwrap(ranked[target.id], query)
            XCTAssertTrue(entry.matchedClues.contains(target.commonName), query)
            XCTAssertEqual(entry.informationLevel, .sufficient, query)
        }
    }

    func testAnAliasSharedByTwoRecordsIsNotAnExactName() async throws {
        let first = try profile("Squaretail grouper", aliases: ["Coral trout"])
        let second = try profile("Leopard grouper", aliases: ["Coral trout"])
        let ranked = try await rank("Coral trout on the reef", [first, second])
        XCTAssertFalse(ranked.values.contains { $0.matchedClues.contains($0.profile.commonName) })
    }

    func testAOneWordCommonNameThatIsAlsoAGroupNounIsNotAnExactName() async throws {
        let group = try profile("Angelfish")
        let french = try profile("French angelfish")
        let hogfish = try profile("Hogfish")
        let bare = try await rank("Angelfish on the reef", [group, french, hogfish])
        // The group word names both angelfish records, as limited information, and no exact name.
        XCTAssertFalse(try XCTUnwrap(bare[group.id]).matchedClues.contains("Angelfish"))
        XCTAssertEqual(try XCTUnwrap(bare[french.id]).informationLevel, .limited)
        XCTAssertNil(bare[hogfish.id], "a hogfish is not an angelfish")
        let ranked = try await rank("Blue angelfish on the reef", [group, french, hogfish])
        XCTAssertFalse(try XCTUnwrap(ranked[group.id]).matchedClues.contains("Angelfish"))
        // A one-word name nothing else ends in still names its species.
        let hog = try await rank("Hogfish on the reef", [group, french, hogfish])
        XCTAssertTrue(try XCTUnwrap(hog[hogfish.id]).matchedClues.contains("Hogfish"))
    }

    func testANameInsideAHyphenatedCompoundIsNotAnExactName() async throws {
        let orange = try profile("Yellow clownfish", aliases: ["Orange anemonefish"])
        let compound = try await rank("Red-orange anemonefish on the reef", [orange])
        XCTAssertFalse(compound[orange.id]?.matchedClues.contains("Yellow clownfish") ?? false)
        let plain = try await rank("Orange anemonefish on the reef", [orange])
        XCTAssertTrue(try XCTUnwrap(plain[orange.id]).matchedClues.contains("Yellow clownfish"))
        XCTAssertTrue(LocalSpeciesRanker.namesSubject("orange anemonefish", in: "an orange anemonefish, red-orange anemonefish nearby"))
        XCTAssertFalse(LocalSpeciesRanker.namesSubject("lined surgeonfish", in: "blue-lined surgeonfish"))
    }

    /// v05-ambiguous-trigger, synthetically: a group alias used to force `.sufficient`
    /// information and lift confidence over the 0.64 ceiling for limited descriptions.
    func testAGroupAliasDoesNotRaiseConfidenceAboveTheLimitedCeiling() async throws {
        let triggers = try (0..<3).map { try profile("Synthetic \($0) triggerfish", aliases: ["Triggerfish"], colors: ["black"]) }
        let ranked = try await rank("Dark triggerfish on an outer reef.", triggers)
        XCTAssertFalse(ranked.isEmpty)
        for entry in ranked.values {
            XCTAssertEqual(entry.informationLevel, .limited)
            XCTAssertLessThanOrEqual(entry.score, 0.64)
        }
    }

    // MARK: Appearance variants

    func testVariantEvidenceAlreadyCreditedByTheMainProfileIsNotCountedAgain() async throws {
        let duplicated = try profile("Duplicated", colors: ["yellow"], variants: [variant("juvenile", colors: ["yellow"])])
        let plain = try profile("Plain", colors: ["yellow"])
        let ranked = try await rank("Yellow fish on the reef", [duplicated, plain])
        XCTAssertEqual(ranked[duplicated.id]?.rawScore, ranked[plain.id]?.rawScore)
        XCTAssertNil(ranked[duplicated.id]?.matchedAppearanceVariant)
    }

    func testMutuallyExclusiveVariantsDoNotStack() async throws {
        let sexes = try profile("Dichromatic", variants: [variant("male", colors: ["blue"]), variant("female", colors: ["green"])])
        let single = try profile("Monochromatic", variants: [variant("male", colors: ["blue"])])
        let ranked = try await rank("Blue and green fish on the reef", [sexes, single])
        // Only the best variant counts; the female colours do not add to the male's.
        XCTAssertEqual(ranked[sexes.id]?.rawScore, ranked[single.id]?.rawScore)
    }

    func testANamedLifeStageExcludesOtherStagesAndAnUnknownStageIsNeutral() async throws {
        let target = try profile("Staged", variants: [variant("male", colors: ["blue"]), variant("juvenile", colors: ["yellow"])])
        let juvenile = try await rank("Juvenile blue fish on the reef", [target])
        XCTAssertNil(juvenile[target.id]?.matchedAppearanceVariant, "a male colour is not evidence for a juvenile")
        let unknown = try await rank("Blue fish on the reef", [target])
        let entry = try XCTUnwrap(unknown[target.id])
        XCTAssertEqual(entry.matchedAppearanceVariant?.lifeStage, .male)
        XCTAssertTrue(entry.conflictingClues.isEmpty, "an unknown stage is uncertainty, not contradiction")
        XCTAssertEqual(LocalSpeciesRanker.namedLifeStages(["female"]), [.female, .initialPhase])
        XCTAssertTrue(LocalSpeciesRanker.namedLifeStages(["fish", "reef"]).isEmpty)
    }

    // MARK: Appearance relationships

    func testCoordinatedColoursApplyToTheFollowingMarking() {
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "Blue and yellow stripes with black edges"), ["blue stripes", "yellow stripes"])
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "black, white or gray spots"), ["black spots", "white spots", "gray spots"])
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "blue body and yellow fins"), [])
    }

    func testFrontToRearContrastIsOneRelationshipEitherWayRound() {
        for text in ["Front half paler than the rear.", "pale front half and darker rear", "anterior half of body abruptly paler", "darker rear"] {
            XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: text), ["paler front"], text)
        }
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "dark front and pale rear"), ["paler rear"])
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "dark back"), [])
    }

    func testLikeSuffixAndMaroon() async {
        XCTAssertEqual(LocalObservationParser.likeStem("birdlike"), "bird")
        XCTAssertEqual(LocalObservationParser.likeStem("Leaflike"), "leaf")
        XCTAssertNil(LocalObservationParser.likeStem("like"))
        XCTAssertNil(LocalObservationParser.likeStem("alike"))
        let observation = await LocalObservationParser().parse("maroon fish with a birdlike snout")
        XCTAssertTrue(observation.colors.contains("red"))
        XCTAssertTrue(observation.tokens.contains("bird"))
        XCTAssertTrue(BM25SpeciesCandidateRetriever.terms("a leaflike fish").contains("leaf"))
    }
}
