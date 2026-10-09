import XCTest
@testable import DiveID

final class LocalObservationParserMeasurementTests: XCTestCase {
    private let parser = LocalObservationParser()

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
