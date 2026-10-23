import Foundation
import XCTest
@testable import DiveID

final class LocalObservationParserMeasurementTests: XCTestCase {
    private let parser = LocalObservationParser()

    func testAppearanceRelationshipsAreCanonicalAndDoNotCrossListsOrNegation() async {
        for phrase in ["blue stripes", "BLUE-striped", "blue bands", "blue fine bars"] {
            let parsed = await parser.parse(phrase)
            XCTAssertEqual(parsed.appearanceRelationships, ["blue stripes"], phrase)
        }
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "gold dots; yellow spots; gold-spotted"), ["yellow spots"])
        for phrase in ["blue, yellow; stripes", "blue | stripes", "no blue stripes", "not blue-striped"] {
            XCTAssertTrue(AppearanceEvidenceVocabulary.appearanceRelationships(in: phrase).isEmpty, phrase)
        }
        let compound = await parser.parse("orange-red fish")
        XCTAssertEqual(compound.colorEvidenceGroups, [["orange", "red"]])
        let coordinated = await parser.parse("orange and red fish")
        XCTAssertEqual(coordinated.colorEvidenceGroups.count, 2)
        XCTAssertEqual(AppearanceEvidenceVocabulary.appearanceRelationships(in: "blue-green head; green-blue head"), ["blue-green hue"])
        let tokens = BM25SpeciesCandidateRetriever.terms("blue stripes | blue bands | blue stripes")
        XCTAssertEqual(tokens.filter { $0 == "appearancebluestripes" }.count, 1)
    }

    func testSpineDescriptionsShareOneEvidenceGroupAndRespectWordBoundaries() async {
        for description in ["fish with dorsal needles", "spiny reef fish", "spiky fins", "fish with spines"] {
            let observation = await parser.parse(description)
            XCTAssertEqual(observation.markings, ["spines"], description)
        }
        for description in ["needlefish on a reef", "spineless animal", "spinnaker sail"] {
            let observation = await parser.parse(description)
            XCTAssertFalse(observation.markings.contains("spines"), description)
        }
    }

    func testExplicitContextAssignsOneRolePerMeasurementOccurrence() async {
        await assertMeasurement("around 10 m deep", size: nil, depth: 10)
        await assertMeasurement("about 10 cm long", size: 10, depth: nil)
        await assertMeasurement("🐠 près du récif, around 10 m deep", size: nil, depth: 10)
    }

    func testDistinctOccurrencesCanSupplySizeAndDepth() async {
        await assertMeasurement("a 10 cm fish at 10 m deep", size: 10, depth: 10)
        await assertMeasurement("10 m long at 10 m depth", size: 1_000, depth: 10)
        await assertMeasurement("at 10 m depth, a 10 m long fish", size: 1_000, depth: 10)
        await assertMeasurement("at 10 m deep, a 10 cm long fish", size: 10, depth: 10)
    }

    func testExistingApproximateMeasurementsAndConversionsRemainSupported() async {
        await assertMeasurement("around 60 feet deep", size: nil, depth: 18.288)
        await assertMeasurement("roughly 12 inches long", size: 30.48, depth: nil)
        await assertMeasurement("length about 2 meters", size: 200, depth: nil)
        await assertMeasurement("a fish at a depth of 20 meters", size: nil, depth: 20)
    }

    private func assertMeasurement(
        _ description: String,
        size: Double?,
        depth: Double?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let observation = await parser.parse(description)
        if let size {
            XCTAssertEqual(observation.approximateSizeCentimeters ?? -1, size, accuracy: 0.001, file: file, line: line)
        } else {
            XCTAssertNil(observation.approximateSizeCentimeters, file: file, line: line)
        }
        if let depth {
            XCTAssertEqual(observation.approximateDepthMeters ?? -1, depth, accuracy: 0.001, file: file, line: line)
        } else {
            XCTAssertNil(observation.approximateDepthMeters, file: file, line: line)
        }
    }
}

final class LocationRecognitionTests: XCTestCase {
    func testWholePhrasesPreserveNamesAndNormalizeExistingVariants() async {
        let examples: [(String, Set<String>)] = [
            ("fish in the BAHAMAS.", ["bahamas"]),
            ("near the Philippines!", ["philippines"]),
            ("Gulf-of-Mexico reef", ["gulf of mexico"]),
            ("near TURKS, AND CAICOS", ["turks and caicos"]),
            ("Curaçao / Curacao", ["curacao"]),
            ("Western Atlantic", ["western atlantic"]),
            ("Indo-Pacific", ["indo-pacific"]),
            ("Tropical Pacific", ["tropical pacific"]),
            ("British Virgin Islands", ["british virgin islands"])
        ]
        for (text, expected) in examples {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertEqual(observation.regions, expected, text)
        }
    }

    func testUnknownPartialAndSubstringLocationsDoNotEstablishRegion() async {
        for text in ["fish near Atlantis", "Indianapolis reef", "Fijian fish", "Virgin Islands", "Cayman", "fish on a reef"] {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertEqual(observation.regions, [], text)
            XCTAssertEqual(RegionCompatibilityResolver().compatibility(observedRegions: observation.regions, supportedRegions: ["caribbean"]), .unspecified)
        }
    }

    func testConflictingAlternativesRemainUnspecified() async {
        let observation = await LocalObservationParser().parse("Was it in Fiji or the Bahamas?")
        XCTAssertEqual(observation.regions, ["fiji", "bahamas"])
        XCTAssertEqual(RegionCompatibilityResolver().compatibility(observedRegions: observation.regions, supportedRegions: ["caribbean"]), .unspecified)
    }

    func testEveryBundledAliasIsRecognizedAndCompatibleOnlyWithItsPack() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        for packID in [OfflineIdentificationPackID.caribbean, .tropicalPacific] {
            let pack = try await repository.loadPack(id: packID)
            let other = try await repository.loadPack(id: packID == .caribbean ? .tropicalPacific : .caribbean)
            for alias in pack.metadata.regionAliases {
                let observation = await LocalObservationParser().parse("Fish on a reef in \(alias).")
                XCTAssertFalse(observation.regions.isEmpty, alias)
                let resolver = RegionCompatibilityResolver()
                XCTAssertEqual(resolver.compatibility(observedRegions: observation.regions, supportedRegions: Set(pack.metadata.regionAliases)), .compatible, alias)
                XCTAssertEqual(resolver.compatibility(observedRegions: observation.regions, supportedRegions: Set(other.metadata.regionAliases)), .conflicting, alias)
            }
        }
    }

    func testServiceRejectsRecognizedWrongPackButNotUnknownLocation() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
        let service = LocalMarineLifeIdentificationService(catalogRepository: repository)
        for location in ["Gulf of Mexico", "Curaçao", "Turks and Caicos"] {
            do {
                _ = try await service.identify(request: .init(source: .description("Blue reef fish in \(location)."), context: .init(region: .tropicalPacific)), processedPhoto: nil)
                XCTFail("Expected mismatch for \(location)")
            } catch LocalIdentificationError.regionMismatch(let selected, _) {
                XCTAssertEqual(selected, .tropicalPacific)
            }
        }
        for location in ["Atlantis", "Virgin Islands", "Fiji"] {
            _ = try await service.identify(request: .init(source: .description("Blue reef fish in \(location)."), context: .init(region: .tropicalPacific)), processedPhoto: nil)
        }
    }
}

final class ObservationDomainPolicyTests: XCTestCase {
    func testExplicitAmphibianSubjectsAreDecisiveDespiteSharedClues() async {
        for text in [
            "A spotted freshwater frog on sand, about 5 cm long.",
            "Freshwater frog sitting on a lily pad.",
            "I saw a small green toad swimming over sand.",
            "It was a striped amphibian with a long tail.",
            "We observed large brown frogs near a reef."
        ] {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertEqual(observation.domainContradiction, .amphibianSubject, text)
        }
    }

    func testNegationComparisonObjectsAndUncertaintyAreNotSubjectAssertions() async {
        for text in [
            "Not a frog, a spotted fish on sand.",
            "It was not a frog but a reef fish.",
            "A frog-like face on a spotted fish.",
            "A frog shaped head on a fish.",
            "A frog face, with fins and scales.",
            "A fish with a face like a frog.",
            "A fish eating a frog over sand.",
            "Maybe a frog on sand.",
            "A frog or a fish swimming on sand.",
            "A frog and a fish swimming on sand.",
            "Was it a frog?",
            "A frogfish on the reef.",
            "A toadfish over sand.",
            "An unfamiliar glorp swimming over sand."
        ] {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertNil(observation.domainContradiction, text)
        }
        for category in CatalogueVocabulary.categories {
            let observation = await LocalObservationParser().parse("A spotted \(category) swimming over sand.")
            XCTAssertNil(observation.domainContradiction, category)
        }
    }
}

final class ObservationEvidenceScopeTests: XCTestCase {
    func testMeasurementRoleWordsDoNotBecomeShapeOrHabitat() async {
        for text in ["a fish 5 cm long at 8 m deep", "🐠 a fish about 2 inches long at 20 feet deep"] {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertNotNil(observation.approximateSizeCentimeters)
            XCTAssertNotNil(observation.approximateDepthMeters)
            XCTAssertFalse(observation.bodyShapes.contains("elongated"), text)
            XCTAssertFalse(observation.habitats.contains("deep"), text)
        }
        let independent = await LocalObservationParser().parse("A long fish in deep water, 20 cm long at 40 m deep.")
        XCTAssertTrue(independent.bodyShapes.contains("elongated"))
        XCTAssertTrue(independent.habitats.contains("deep"))
        XCTAssertEqual(independent.approximateSizeCentimeters, 20)
        XCTAssertEqual(independent.approximateDepthMeters, 40)
    }

    func testNegatedCompoundCluesDoNotBecomePositiveTraits() async {
        for text in ["A blue fish with no bright pink tail.", "A blue fish without spots.", "Not a red fish, but a blue fish."] {
            let observation = await LocalObservationParser().parse(text)
            XCTAssertEqual(observation.colors, ["blue"], text)
            XCTAssertFalse(observation.markings.contains("tail"), text)
            XCTAssertFalse(observation.markings.contains("spots"), text)
        }
        let continued = await LocalObservationParser().parse("No stripes but a red patch and blue spots.")
        XCTAssertEqual(continued.markings, ["patches", "spots"])
        XCTAssertEqual(continued.colors, ["red", "blue"])
        let additive = await LocalObservationParser().parse("Not only blue but yellow spots.")
        XCTAssertEqual(additive.colors, ["blue", "yellow"])
    }
}

final class MorphologyConceptTests: XCTestCase {
    func testBodyAndFinConceptsRemainIndependent() async {
        let parser = LocalObservationParser()
        for text in ["leaflike body", "LEAF-LIKE fish", "body shaped like a leaf", "leaf-shaped animal", "leaflike small fish"] {
            let value = await parser.parse(text)
            XCTAssertEqual(value.bodyShapes, ["leaflike"], text)
            XCTAssertFalse(value.markings.contains("spines"))
        }
        for text in ["tall dorsal fin", "high first dorsal fin", "dorsal fin is elevated"] {
            let value = await parser.parse(text)
            XCTAssertTrue(value.tokens.contains("tall dorsal fin"), text)
            XCTAssertTrue(value.bodyShapes.isEmpty)
            XCTAssertFalse(value.markings.contains("spines"))
        }
        for text in ["leaflike dorsal fin", "leaf-like dorsal fin", "fish among leaves", "not a leaflike body", "without a tall dorsal fin"] {
            let value = await parser.parse(text)
            XCTAssertFalse(value.bodyShapes.contains("leaflike"), text)
            XCTAssertFalse(value.tokens.contains("tall dorsal fin"), text)
        }
    }

    func testFinParaphrasesAndUnknowns() {
        XCTAssertEqual(MorphologyVocabulary.concepts(in: "sail-like dorsal fin"),
                       MorphologyVocabulary.concepts(in: "dorsal fin shaped like a sail"))
        XCTAssertEqual(MorphologyVocabulary.concepts(in: "threadlike first dorsal fin"), ["filamentous dorsal fin"])
        XCTAssertTrue(MorphologyVocabulary.concepts(in: "rounded tail and unknown body").isEmpty)
        XCTAssertEqual(MorphologyVocabulary.concepts(in: "tall dorsal fin and high dorsal fin"), ["tall dorsal fin"])
    }
}


extension MorphologyConceptTests {
    func testMultipleSpeciesFinEvidenceAliasesAndUnknownNeutrality() async throws {
        let pack = try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle,
            access: .experimentalDevelopment).loadPack(id: .tropicalPacific)
        let observation = await LocalObservationParser().parse("fish with a tall dorsal fin")
        for name in ["Cockatoo Waspfish", "Fire Dartfish"] {
            let original = try XCTUnwrap(pack.profiles.first { $0.commonName == name })
            var unknown = original
            unknown.finAndSpineClues = []
            var aliases = original
            aliases.finAndSpineClues += ["high dorsal fin", "dorsal fin is raised"]
            let ranker = LocalSpeciesRanker()
            let knownResults = try await ranker.rank(observation: observation, profiles: [original])
            let unknownResults = try await ranker.rank(observation: observation, profiles: [unknown])
            let aliasResults = try await ranker.rank(observation: observation, profiles: [aliases])
            let known = try XCTUnwrap(knownResults.first)
            let absent = try XCTUnwrap(unknownResults.first)
            XCTAssertEqual(known.rawScore - absent.rawScore, 2)
            XCTAssertEqual(known.rawScore, aliasResults.first?.rawScore)
            XCTAssertEqual(known.conflictingClues, absent.conflictingClues)
            XCTAssertTrue(known.matchedClues.contains("tall dorsal fin"))
            let docs = [SpeciesSearchDocumentBuilder().document(from: original, pack: pack.metadata)]
            let a = try await BM25SpeciesCandidateRetriever().retrieve(query: "tall dorsal fin", documents: docs, limit: 50)
            let b = try await BM25SpeciesCandidateRetriever().retrieve(query: "high dorsal fin and elevated dorsal fin", documents: docs, limit: 50)
            XCTAssertEqual(a.first?.retrievalScore, b.first?.retrievalScore)
            XCTAssertFalse(a.isEmpty)
        }
    }
}

extension MorphologyConceptTests {
    func testLeafBodyRanksAsBodyEvidenceWithoutInferringFinOrContradiction() async throws {
        let pack = try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle,
            access: .experimentalDevelopment).loadPack(id: .caribbean)
        // Synthetic morphology fixtures, not source claims or publication approval.
        for base in pack.profiles.prefix(2) {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
            object["bodyShapes"] = ["leaflike"]
            object["categories"] = ["fish"]
            object["finAndSpineClues"] = []
            let leaf = try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
            object["bodyShapes"] = []
            let unknown = try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONSerialization.data(withJSONObject: object))
            let observation = await LocalObservationParser().parse("leaf-shaped fish")
            let a = try await LocalSpeciesRanker().rank(observation: observation, profiles: [leaf])
            let b = try await LocalSpeciesRanker().rank(observation: observation, profiles: [unknown])
            XCTAssertEqual(try XCTUnwrap(a.first).rawScore - XCTUnwrap(b.first).rawScore, 3)
            XCTAssertEqual(a.first?.conflictingClues, b.first?.conflictingClues)
            XCTAssertTrue(observation.markings.isEmpty)
        }
    }

    // MARK: Normalization

    /// The regex implementation `normalize` replaced, kept as the reference.
    private func referenceNormalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[-/]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9. ]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    func testNormalizeMatchesTheRegexImplementation() async throws {
        var samples = [
            "", " ", "  Blue-Green Wrasse  ", "A/B--c", "Dorsal fin: 17–18 spines, 6–7 soft rays.", "..x..", "\tTab\nnew\r\nline ",
            "\u{00A0}non-breaking\u{00A0}", "İstanbul", "Kelvin \u{212A} sign", "ÉCOLE élève", "e\u{0301}clair", "🐠 fish 🐟", "x\u{2028}y",
            "-leading", "trailing-", "Ünïcödé–mixed / ASCII", "\u{3000}ideographic space\u{3000}", "100 × 20 cm", "ﬁsh ligature", "ß STRASSE"
        ]
        let pack = try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
            .loadPack(id: .tropicalPacific)
        for profile in pack.profiles.prefix(400) {
            samples += [profile.commonName, profile.scientificName, profile.summary] + profile.aliases + profile.distinguishingFeatures
        }
        for sample in samples {
            XCTAssertEqual(LocalObservationParser.normalize(sample), referenceNormalize(sample), sample.debugDescription)
        }
    }
}

/// Synonym expansion is a single pass over the description's own tokens (Codex P2): a
/// rule never matches a key that another rule added, and the result is the same on every
/// launch, whatever order the synonym dictionary iterates in.
final class SynonymExpansionTests: XCTestCase {
    private let parser = LocalObservationParser()
    private static let sandyChannel = "a school of spotted rays crossed the sandy channel"
    private static let outputVariable = "DIVEID_PARSER_TOKENS_OUTPUT"

    func testSandyAddsSandButNotBottomSwimming() async {
        let observation = await parser.parse(Self.sandyChannel)
        XCTAssertTrue(observation.tokens.contains("sand"))
        XCTAssertTrue(observation.habitats.contains("sand"))
        XCTAssertFalse(observation.tokens.contains("bottom-swimming"))
        XCTAssertFalse(observation.behaviors.contains("bottom-swimming"))
        // The rule still applies to the description's own words.
        for text in ["ray resting on sand", "ray over a sandy bottom"] {
            let direct = await parser.parse(text)
            XCTAssertTrue(direct.behaviors.contains("bottom-swimming"), text)
        }
    }

    func testRulesNeverMatchKeysThatOtherRulesAdded() {
        // "second" matches only through the key "first" adds.
        let rules = [(key: "first", values: Set(["word"])), (key: "second", values: Set(["first"]))]
        for ordered in [rules, rules.reversed()] {
            XCTAssertEqual(LocalObservationParser.expandingSynonyms(["word"], normalizedText: "word", rules: ordered), ["word", "first"])
        }
    }

    func testExpansionDoesNotDependOnRuleOrder() throws {
        var generator = SplitMix64(seed: 0x5EED)
        let rules = LocalObservationVocabulary.synonyms.map { (key: $0.key, values: $0.value) }.sorted { $0.key < $1.key }
        for description in try Self.descriptions() {
            let text = LocalObservationParser.normalize(description)
            let tokens = Set(text.split(separator: " ").map { LocalObservationParser.singular(String($0)) })
            let expected = LocalObservationParser.expandingSynonyms(tokens, normalizedText: text, rules: rules)
            XCTAssertEqual(LocalObservationParser.expandingSynonyms(tokens, normalizedText: text, rules: rules.reversed()), expected, description)
            for _ in 0..<8 {
                XCTAssertEqual(LocalObservationParser.expandingSynonyms(tokens, normalizedText: text, rules: rules.shuffled(using: &generator)), expected, description)
            }
        }
    }

    func testRepeatedParsesGiveIdenticalTokens() async throws {
        let descriptions = try Self.descriptions()
        let first = await tokens(for: descriptions)
        for _ in 0..<20 {
            let again = await tokens(for: descriptions)
            XCTAssertEqual(again, first)
        }
    }

    /// Swift seeds hashing per process, so only separate processes exercise different
    /// dictionary orders. Each child reruns this test with `outputVariable` set, writes its
    /// tokens and a probe of its Set order, and exits. The probe shows the seeds differed.
    func testSeparateProcessesGiveIdenticalTokens() async throws {
        let descriptions = try Self.descriptions()
        let environment = ProcessInfo.processInfo.environment
        if let path = environment[Self.outputVariable] {
            let output = ChildOutput(setOrder: Array(Set((0..<64).map(String.init))), tokens: await tokens(for: descriptions))
            try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: path))
            return
        }
#if os(macOS) || os(Linux)
        let executable = try XCTUnwrap(Bundle.main.executablePath)
        let test = String(reflecting: Self.self) + "/testSeparateProcessesGiveIdenticalTokens"
        let arguments: [String]
#if os(macOS)
        // SwiftPM runs XCTest bundles with the `xctest` tool.
        guard URL(fileURLWithPath: executable).lastPathComponent == "xctest" else {
            throw XCTSkip("Not running under xctest: \(executable)")
        }
        arguments = ["-XCTest", test, Bundle(for: Self.self).bundlePath]
#else
        arguments = [test]
#endif
        var child = environment
        child.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parser-tokens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var outputs: [ChildOutput] = []
        for run in 0..<4 {
            let path = directory.appendingPathComponent("\(run).json")
            child[Self.outputVariable] = path.path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = child
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "child \(run)")
            outputs.append(try JSONDecoder().decode(ChildOutput.self, from: Data(contentsOf: path)))
        }
        XCTAssertGreaterThan(Set(outputs.map(\.setOrder)).count, 1, "child processes shared one hash seed")
        let expected = await tokens(for: descriptions)
        for (run, output) in outputs.enumerated() { XCTAssertEqual(output.tokens, expected, "child \(run)") }
#else
        throw XCTSkip("Child processes are unavailable on this platform")
#endif
    }

    private struct ChildOutput: Codable { let setOrder: [String]; let tokens: [[String]] }

    private func tokens(for descriptions: [String]) async -> [[String]] {
        var result: [[String]] = []
        for description in descriptions { result.append(await parser.parse(description).tokens.sorted()) }
        return result
    }

    /// Every query of the golden search outputs.
    private static func descriptions() throws -> [String] {
        let golden = try JSONSerialization.jsonObject(with: Data(contentsOf: TestResources.fixture(named: "SearchGolden.v2"))) as? [String: Any]
        let queries = try XCTUnwrap(golden?["queries"] as? [String])
        XCTAssertTrue(queries.contains(sandyChannel))
        return queries
    }
}

/// A seeded generator, so a failing shuffle can be reproduced.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
