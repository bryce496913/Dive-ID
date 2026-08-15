import XCTest
@testable import DiveID

final class CanonicalSpeciesSchemaTests: XCTestCase {
    private let parser = LocalObservationParser()

    func testProfileConversionPreservesEveryEnrichedField() throws {
        let profile = try enrichedProfile()
        let species = profile.species

        XCTAssertEqual(species.taxonomy, profile.taxonomy)
        XCTAssertEqual(species.measurements, profile.measurements)
        XCTAssertEqual(species.tailShape, "crescent tail")
        XCTAssertEqual(species.mouthAndHeadShape, ["blunt snout", "small beak-like mouth"])
        XCTAssertEqual(species.finAndSpineClues, ["long dorsal spines", "distinctive sail fin"])
    }

    func testIdentificationResultCarriesCanonicalEnrichment() async throws {
        let profile = try enrichedProfile()
        let service = LocalMarineLifeIdentificationService(catalogRepository: StaticCatalogRepository(profiles: [profile]), parser: parser, ranker: LocalSpeciesRanker())
        let matches = try await service.identify(request: IdentificationRequest(source: .description("fish with crescent tail and blunt snout plus long dorsal spines")), processedPhoto: nil)

        let species = try XCTUnwrap(matches.first?.species)
        XCTAssertEqual(species.taxonomy, profile.taxonomy)
        XCTAssertEqual(species.measurements, profile.measurements)
        XCTAssertEqual(species.tailShape, profile.tailShape)
        XCTAssertEqual(species.mouthAndHeadShape, profile.mouthAndHeadShape)
        XCTAssertEqual(species.finAndSpineClues, profile.finAndSpineClues)
    }

    func testSavingAndReopeningResultRetainsCanonicalEnrichment() async throws {
        let profile = try enrichedProfile()
        let species = profile.species
        let match = IdentificationMatch(id: species.id, species: species, score: 0.8, scoreKind: .relativeMatch)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("saved.json")

        let repository = try JSONSavedIdentificationRepository(fileURL: fileURL)
        let saved = try await repository.save(SavedIdentification(match: match))
        XCTAssertEqual(saved.species.taxonomy, profile.taxonomy)
        XCTAssertEqual(saved.species.measurements, profile.measurements)
        XCTAssertEqual(saved.species.tailShape, profile.tailShape)
        XCTAssertEqual(saved.species.mouthAndHeadShape, profile.mouthAndHeadShape)
        XCTAssertEqual(saved.species.finAndSpineClues, profile.finAndSpineClues)

        let reopened = try XCTUnwrap(try await JSONSavedIdentificationRepository(fileURL: fileURL).fetchAll().first)
        XCTAssertEqual(reopened.species, species)
        XCTAssertEqual(reopened.match.species, species)
    }

    func testTailHeadAndFinCluesContributeIndependentVisibleEvidence() async throws {
        let baseline = try enrichedProfile(tailShape: nil, mouthAndHeadShape: [], finAndSpineClues: [])
        let cases: [(String, LocalSpeciesProfile, String)] = [
            ("fish animal with a crescent tail swimming", try enrichedProfile(tailShape: "crescent tail", mouthAndHeadShape: [], finAndSpineClues: []), "tail shape"),
            ("fish animal with a blunt snout swimming", try enrichedProfile(tailShape: nil, mouthAndHeadShape: ["blunt snout"], finAndSpineClues: []), "head and mouth shape"),
            ("fish animal with long dorsal spines swimming", try enrichedProfile(tailShape: nil, mouthAndHeadShape: [], finAndSpineClues: ["long dorsal spines"]), "fin and spine clues")
        ]

        for (description, enriched, expectedClue) in cases {
            let observation = await parser.parse(description)
            let ranked = try await LocalSpeciesRanker().rank(observation: observation, profiles: [enriched, baseline])
            XCTAssertEqual(ranked.first?.profile.id, enriched.id)
            XCTAssertEqual(ranked.first?.rawScore, (ranked.last?.rawScore ?? 0) + 2)
            XCTAssertTrue(ranked.first?.matchedClues.contains(expectedClue) == true)
        }
    }

    func testOverlappingLegacyClueIsNotDoubleCounted() async throws {
        let legacyOnly = try enrichedProfile(keywords: ["tail"], tailShape: nil, mouthAndHeadShape: [], finAndSpineClues: [])
        let overlapping = try enrichedProfile(keywords: ["tail"], tailShape: "crescent tail", mouthAndHeadShape: [], finAndSpineClues: [])
        let observation = await parser.parse("fish animal with crescent tail swimming")
        let results = try await LocalSpeciesRanker().rank(observation: observation, profiles: [legacyOnly, overlapping])

        XCTAssertEqual(results.map(\.rawScore), [results[0].rawScore, results[0].rawScore])
        XCTAssertFalse(results.flatMap(\.matchedClues).contains("tail shape"))
    }

    func testEmptyEnrichedFieldsDoNotChangeExistingRanking() async throws {
        let existing = try enrichedProfile(tailShape: nil, mouthAndHeadShape: [], finAndSpineClues: [])
        let roundTripped = try JSONDecoder().decode(LocalSpeciesProfile.self, from: JSONEncoder().encode(existing))
        let observation = await parser.parse("silver fish swimming around coral reef")
        let ranker = LocalSpeciesRanker()

        let before = try await ranker.rank(observation: observation, profiles: [existing]).first
        let after = try await ranker.rank(observation: observation, profiles: [roundTripped]).first
        XCTAssertEqual(before?.rawScore, after?.rawScore)
        XCTAssertEqual(before?.matchedClues, after?.matchedClues)
    }

    func testRankingPrefersCanonicalMeasurementRangeOverLegacyBounds() async throws {
        let profile = try enrichedProfile(tailShape: nil, mouthAndHeadShape: [], finAndSpineClues: [])
        let observation = await parser.parse("80 cm fish swimming around a reef")
        let ranked = try await LocalSpeciesRanker().rank(observation: observation, profiles: [profile])

        XCTAssertTrue(ranked.first?.conflictingClues.contains("described size") == true)
        XCTAssertFalse(ranked.first?.matchedClues.contains("compatible size") == true)
    }

    @MainActor
    func testSpeciesDetailFormatsAvailableTaxonomyAndMeasurements() throws {
        let species = try enrichedProfile().species
        XCTAssertTrue(SpeciesDetailView.taxonomyText(try XCTUnwrap(species.taxonomy)).contains("Family: Testidae"))
        XCTAssertTrue(SpeciesDetailView.measurementsText(try XCTUnwrap(species.measurements)).contains("20–40 cm"))
    }

    private func enrichedProfile(keywords: [String] = [], tailShape: String? = "crescent tail", mouthAndHeadShape: [String] = ["blunt snout", "small beak-like mouth"], finAndSpineClues: [String] = ["long dorsal spines", "distinctive sail fin"]) throws -> LocalSpeciesProfile {
        let tailJSON = tailShape.map { "\"\($0)\"" } ?? "null"
        let strings: ([String]) throws -> String = { values in String(decoding: try JSONEncoder().encode(values), as: UTF8.self) }
        let json = """
        {"id":"\(UUID().uuidString)","commonName":"Schema Fish","scientificName":"Schema exemplar","aliases":[],"categories":["fish"],"colors":["silver"],"markings":[],"bodyShapes":[],"habitats":["reef"],"regions":[],"behaviors":["swimming"],"keywords":\(try strings(keywords)),"minimumSizeCentimeters":10,"maximumSizeCentimeters":100,"minimumDepthMeters":1,"maximumDepthMeters":20,"summary":"A synthetic test species.","distinguishingFeatures":["Test feature"],"typicalHabitat":"Reef","geographicRange":"Test range","cautions":[],"imageAssetName":null,"taxonomy":{"wormsAphiaID":123,"scientificNameAuthority":"Tester, 2026","taxonomicClass":"Actinopterygii","order":"Testiformes","family":"Testidae","genus":"Schema","acceptedScientificName":"Schema exemplar","sourceScientificName":"Schema exemplar"},"measurements":{"typicalObservedMinimumCentimeters":20,"typicalObservedMaximumCentimeters":40,"maximumRecordedCentimeters":60,"type":"totalLength"},"tailShape":\(tailJSON),"mouthAndHeadShape":\(try strings(mouthAndHeadShape)),"finAndSpineClues":\(try strings(finAndSpineClues))}
        """
        return try JSONDecoder().decode(LocalSpeciesProfile.self, from: Data(json.utf8))
    }
}
