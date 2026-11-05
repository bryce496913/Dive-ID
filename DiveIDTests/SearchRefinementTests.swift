import XCTest
@testable import DiveID

/// Refining a description search: the neutral questions, combining answers with the
/// unchanged description, the same pipeline and rules, sessions and Back, and provenance.
/// The descriptions here are new synthetic development cases, separate from the frozen
/// benchmarks; no existing description, threshold or engine selection changes.
@MainActor
final class SearchRefinementTests: XCTestCase {
    private func refinement(_ answers: [SearchRefinement.Dimension: SearchRefinement.Answer]) -> SearchRefinement { SearchRefinement(answers: answers) }

    private func service() -> LocalMarineLifeIdentificationService {
        LocalMarineLifeIdentificationService(catalogRepository: TestResources.catalogRepository(resourceResolutionMode: .bundleOnly, access: .publication),
                                             searchEngine: ConfiguredDescriptionSearchEngine(selection: .productionDefault, bundle: TestResources.productionBundle))
    }

    private func search(_ description: String, _ refinement: SearchRefinement? = nil) async throws -> [IdentificationMatch] {
        var context = IdentificationContext(region: .global)
        context.refinement = refinement
        return try await service().identify(request: .init(source: .description(description), context: context), processedPhoto: nil)
    }

    // MARK: Questions

    func testEveryOptionAddsExactlyTheTraitItNames() async {
        let parser = LocalObservationParser()
        for (dimension, options) in RefinementQuestions.options {
            for option in options {
                let parsed = await parser.parse(option.phrase)
                let traits: Set<String> = switch dimension {
                case .bodyShape: parsed.bodyShapes
                case .markings: parsed.markings
                case .habitat: parsed.habitats
                case .behavior: parsed.behaviors
                case .size: []
                }
                XCTAssertTrue(traits.contains(option.key), "\(dimension) option \(option.label) adds \(traits), not \(option.key)")
            }
        }
        for band in SearchRefinement.SizeBand.allCases {
            let parsed = await parser.parse(band.rawValue)
            XCTAssertEqual(parsed.approximateSizeCentimeters.map(RefinementQuestions.sizeBand(forCentimetres:)), band)
        }
    }

    func testQuestionsAreNeutralAndTheSameForEverySearch() {
        let all = RefinementQuestions.options.values.flatMap { $0 }.map(\.label) + SearchRefinement.Dimension.allCases.map(RefinementQuestions.question)
        for text in all {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("you saw a"), text)
            XCTAssertFalse(text.contains("?") && text.localizedCaseInsensitiveContains("was it a"), "no leading species questions: \(text)")
        }
        XCTAssertTrue(SearchRefinement.Dimension.allCases.allSatisfy { RefinementQuestions.question($0).hasSuffix("?") })
    }

    func testQuestionOrderPutsDescribedTraitsLastAndSplittingQuestionsFirst() async {
        func species(_ name: String, shapes: [String], markings: [String], habitats: [String] = ["reef"]) -> Species {
            var value = Species(id: UUID(), commonName: name, scientificName: name, summary: "", visualCharacteristics: [], habitat: "", geographicRange: "", imageAssetName: nil)
            value.bodyShapes = shapes; value.markings = markings; value.habitats = habitats
            return value
        }
        let candidates = [species("A", shapes: ["flat"], markings: ["spots"]), species("B", shapes: ["flat"], markings: ["stripes"]),
                          species("C", shapes: ["flat"], markings: ["patches"])]
        let described = await LocalObservationParser().parse("flat ray")
        let order = RefinementQuestions.order(observation: described, candidates: candidates)
        XCTAssertEqual(order.first, .markings, "markings split the candidates; shape doesn't")
        XCTAssertEqual(order.last, .bodyShape, "the description already gives a shape")
        XCTAssertEqual(Set(order), Set(SearchRefinement.Dimension.allCases), "every question stays available")
        let noCandidates = RefinementQuestions.order(observation: await LocalObservationParser().parse("something"), candidates: [])
        XCTAssertEqual(noCandidates, SearchRefinement.Dimension.allCases, "no results: the fixed order")
    }

    // MARK: Combining with the description

    func testSkippedNotSureAndNoneAddNothing() async throws {
        let original = "big ray on the sand"
        for empty in [nil, refinement([:]), refinement([.markings: .notSure, .size: .notSure]), refinement([.markings: .noneObserved])] {
            let text = await RefinedSearchText.compose(original: original, refinement: empty)
            XCTAssertEqual(text.searchText, original)
            XCTAssertTrue(text.added.isEmpty)
        }
        let unrefined = try await search(original)
        let unsure = try await search(original, refinement([.markings: .notSure, .behavior: .notSure]))
        XCTAssertEqual(unsure.map(\.species.id), unrefined.map(\.species.id))
        XCTAssertEqual(unsure.map(\.score), unrefined.map(\.score), "unknown answers are neutral")
    }

    func testTheOriginalComesFirstUnchangedAndUnitsAreKept() async {
        let original = "Grey fish, about 1 foot long?"
        let text = await RefinedSearchText.compose(original: original, refinement: refinement([
            .markings: .values(["spots", "stripes"]), .size: .measured(value: 30, unit: .centimetres), .habitat: .values(["reef"])]))
        XCTAssertTrue(text.searchText.hasPrefix(original + ". "), "the description is first, as written")
        XCTAssertEqual(text.added, ["spots", "stripes", "reef"], "1 foot ≈ 30 cm: the same size, not added twice")
        XCTAssertEqual(text.alreadyInDescription, [.size])
        let inches = await RefinedSearchText.compose(original: "blue fish", refinement: refinement([.size: .measured(value: 12, unit: .inches)]))
        XCTAssertEqual(inches.added, ["about 12 inches long"], "kept in the diver's units")
        let parsed = await LocalObservationParser().parse(inches.searchText)
        XCTAssertEqual(parsed.approximateSizeCentimeters ?? 0, 30.48, accuracy: 0.01)
    }

    func testRepeatedInformationIsNotCountedTwice() async throws {
        let original = "flat ray with spots on the sand"
        let repeated = refinement([.bodyShape: .values(["flat"]), .markings: .values(["spots"]), .habitat: .values(["sand"])])
        let text = await RefinedSearchText.compose(original: original, refinement: repeated)
        XCTAssertEqual(text.searchText, original, "everything was already said")
        XCTAssertEqual(text.alreadyInDescription, [.bodyShape, .markings, .habitat])
        let plain = try await search(original)
        let refined = try await search(original, repeated)
        XCTAssertEqual(refined.map(\.species.id), plain.map(\.species.id))
        XCTAssertEqual(refined.map(\.score), plain.map(\.score), "identical scores: no clue scored twice")

        // A synonym the parser treats as the same trait is also recognised ("dotted" is spots).
        let synonym = await RefinedSearchText.compose(original: "dotted ray", refinement: refinement([.markings: .values(["spots", "stripes"])]))
        XCTAssertEqual(synonym.added, ["stripes"])
    }

    func testContradictionsAreKeptAndReported() async throws {
        let shape = await RefinedSearchText.compose(original: "long thin eel", refinement: refinement([.bodyShape: .values(["flat"])]))
        XCTAssertEqual(shape.added, ["flat"], "the answer is kept")
        XCTAssertEqual(shape.disagreements, [.bodyShape])
        XCTAssertTrue(shape.searchText.hasPrefix("long thin eel"), "and so is the description")

        let size = await RefinedSearchText.compose(original: "a fish about 2 m long", refinement: refinement([.size: .measured(value: 10, unit: .centimetres)]))
        XCTAssertEqual(size.disagreements, [.size])
        XCTAssertEqual(size.added, ["about 10 cm long"])
        let parsed = await LocalObservationParser().parse(size.searchText)
        XCTAssertEqual(parsed.approximateSizeCentimeters, 200, "the description's own measurement stays the one used")

        let band = await RefinedSearchText.compose(original: "a fish about 2 m long", refinement: refinement([.size: .sizeBand(.small)]))
        XCTAssertEqual(band.disagreements, [.size])
        let sameBand = await RefinedSearchText.compose(original: "a fish about 2 m long", refinement: refinement([.size: .sizeBand(.large)]))
        XCTAssertEqual(sameBand.alreadyInDescription, [.size])

        // The same confidence rules apply to a contradictory refined search.
        let matches = try await search("long thin eel", refinement([.bodyShape: .values(["flat"])]))
        XCTAssertTrue(matches.allSatisfy { $0.score.isFinite && $0.score <= 1 && ($0.informationLevel != .limited || $0.score <= LocalRankingWeights.limitedConfidenceCap) })
    }

    // MARK: Measured examples on Global (synthetic development cases)

    func testAUsefulClueTurnsAnEmptySearchIntoAnemonefish() async throws {
        let before = try await search("small fish")
        XCTAssertTrue(before.isEmpty, "too little to go on: the engine abstains")
        let after = try await search("small fish", refinement([.markings: .values(["stripes"]), .habitat: .values(["anemone"])]))
        let top = try XCTUnwrap(after.first)
        XCTAssertTrue(top.species.commonName.localizedCaseInsensitiveContains("anemonefish") || top.species.commonName.localizedCaseInsensitiveContains("clownfish"),
                      top.species.commonName)
        XCTAssertTrue(after.allSatisfy { $0.score <= 0.64 }, "still capped at a possible match")
        XCTAssertTrue(after.allSatisfy { $0.observationDescription == "small fish" }, "results keep the description as written")
    }

    func testABlotchedShellMovesHawksbillFirstButKeepsItLimited() async throws {
        let before = try await search("turtle")
        let after = try await search("turtle", refinement([.markings: .values(["patches"])]))
        XCTAssertNotEqual(before.first?.species.commonName, "Hawksbill turtle")
        XCTAssertEqual(after.first?.species.commonName, "Hawksbill turtle")
        XCTAssertEqual(after.first?.informationLevel, .limited, "one word and one clue is still limited information")
    }

    func testAClueThatDoesNotSeparateCandidatesLeavesTheUncertainty() async throws {
        let before = try await search("octopus")
        let after = try await search("octopus", refinement([.markings: .values(["spots"])]))
        XCTAssertEqual(after.first?.score, before.first?.score, "no stronger match is invented")
        XCTAssertEqual(after.first?.informationLevel, .limited)
    }

    // MARK: Sessions, cancellation and Back

    private func resultsModel(_ request: IdentificationRequest, store: InMemoryIdentificationSessionStore) async throws -> IdentificationResultsViewModel {
        let id = try await store.createSession(for: request, photo: nil)
        let model = IdentificationResultsViewModel(sessionID: id, service: service(), sessionStore: store,
                                                   catalog: TestResources.catalogRepository(resourceResolutionMode: .bundleOnly, access: .publication))
        await model.loadIfNeeded()
        return model
    }

    func testARefinedSearchIsANewSessionWithTheSameDescription() async throws {
        let store = InMemoryIdentificationSessionStore()
        let original = try await resultsModel(.init(source: .description("turtle"), context: .init(region: .global)), store: store)
        XCTAssertTrue(original.canRefine)
        XCTAssertFalse(original.isRefined)
        XCTAssertTrue(original.isAmbiguous, "limited matches invite more detail")
        let clue = refinement([.markings: .values(["patches"])])
        let id = try await XCTUnwrapAsync(await original.startRefinedSearch(clue))
        let request = try await store.request(for: id)
        XCTAssertEqual(request.source, .description("turtle"), "the description is unchanged")
        XCTAssertEqual(request.context.refinement, clue)
        XCTAssertEqual(request.context.refinesSessionID, original.sessionID)
        XCTAssertEqual(request.context.region, .global)
        let same = await original.startRefinedSearch(original.currentRefinement)
        XCTAssertNil(same, "nothing changed: no new search")
        let empty = await original.startRefinedSearch(SearchRefinement())
        XCTAssertNil(empty, "no answers on the first search: nothing to search again")

        let refined = IdentificationResultsViewModel(sessionID: id, service: service(), sessionStore: store,
                                                     catalog: TestResources.catalogRepository(resourceResolutionMode: .bundleOnly, access: .publication))
        await refined.loadIfNeeded()
        XCTAssertTrue(refined.isRefined)
        XCTAssertEqual(refined.rootSessionID, original.sessionID)
        guard case .loaded(let matches) = refined.state else { return XCTFail("refined search should load") }
        XCTAssertTrue(matches.allSatisfy { $0.refinement == clue && $0.observationDescription == "turtle" && $0.sourceSessionID == id })
        XCTAssertEqual(refined.refinedText?.added, ["patches"])
    }

    func testANewRefinementReplacesTheOldOneAndBackReturnsToTheFirstSearch() async throws {
        let store = InMemoryIdentificationSessionStore()
        let router = AppRouter(sessionStore: store)
        let first = try await store.createSession(for: .init(source: .description("turtle"), context: .init(region: .global)), photo: nil)
        router.navigate(to: .descriptionSearch)
        router.navigate(to: .identificationResults(sessionID: first))
        let firstClue = refinement([.markings: .values(["patches"])])
        let refinedOne = try await store.createSession(for: .init(source: .description("turtle"), context: { var c = IdentificationContext(region: .global); c.refinement = firstClue; c.refinesSessionID = first; return c }()), photo: nil)
        router.showRefinedResults(refinedOne, refinement: firstClue, root: first, replacingRefined: nil)
        XCTAssertEqual(router.path.last, .identificationResults(sessionID: refinedOne), "from the first search: pushed")
        let model = router.resultsModel(sessionID: refinedOne, service: service(), catalog: TestResources.catalogRepository())
        let secondClue = refinement([.markings: .values(["spots"])])
        let refinedTwo = try await store.createSession(for: .init(source: .description("turtle"), context: { var c = IdentificationContext(region: .global); c.refinement = secondClue; c.refinesSessionID = first; return c }()), photo: nil)
        router.showRefinedResults(refinedTwo, refinement: secondClue, root: first, replacingRefined: refinedOne)
        XCTAssertEqual(router.path, [.descriptionSearch, .identificationResults(sessionID: first), .identificationResults(sessionID: refinedTwo)],
                       "the newer refinement replaces the older one")
        if case .loading = model.state { XCTFail("the superseded search was cancelled") }
        await router.waitForSessionUpdates()
        do { _ = try await store.request(for: refinedOne); XCTFail("the superseded session is released") } catch {}
        XCTAssertEqual(router.latestRefinements[first], secondClue, "reopening Add details shows the latest clues")
        router.goBack()
        XCTAssertEqual(router.path.last, .identificationResults(sessionID: first), "Back returns to the first search")
        let still = try await store.request(for: first)
        XCTAssertNil(still.context.refinement, "the first search is untouched")
    }

    func testRapidRepeatedRefinementsStartOneSearch() async throws {
        let store = InMemoryIdentificationSessionStore()
        let original = try await resultsModel(.init(source: .description("turtle"), context: .init(region: .global)), store: store)
        let clue = refinement([.markings: .values(["patches"])])
        async let one = original.startRefinedSearch(clue)
        async let two = original.startRefinedSearch(clue)
        let started = await [one, two].compactMap { $0 }
        XCTAssertEqual(started.count, 1, "a second tap while one is starting is ignored")
    }

    // MARK: Provenance: save, relaunch, export, backup

    func testRefinementSurvivesSavingRelaunchExportAndBackup() async throws {
        let matches = try await search("turtle", refinement([.markings: .values(["patches"]), .size: .measured(value: 3, unit: .feet), .behavior: .notSure]))
        var match = try XCTUnwrap(matches.first)
        match.refinement = refinement([.markings: .values(["patches"]), .size: .measured(value: 3, unit: .feet), .behavior: .notSure])
        match.observationDescription = "turtle"
        let saved = SavedIdentification(match: match)
        XCTAssertEqual(saved.observationDescription, "turtle")
        XCTAssertEqual(saved.refinement, match.refinement)
        XCTAssertEqual(saved.match.refinement, match.refinement)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("saved.json")
        _ = try await JSONSavedIdentificationRepository(fileURL: file).save(saved)
        let relaunched = try await JSONSavedIdentificationRepository(fileURL: file).fetchAll()
        XCTAssertEqual(relaunched.first?.refinement, saved.refinement, "kept through relaunch")
        XCTAssertEqual(relaunched.first?.observationDescription, "turtle")

        let export = DiveLogExport.wholeLog([], unassigned: relaunched)
        let rows = DiveLogScreenTests.parseCSV(export.csv())
        let column = try XCTUnwrap(rows[0].firstIndex(of: "observation_details_added"))
        XCTAssertEqual(rows[1][column], "Markings: Patches or blotches; Size: About 3 ft; What it was doing: Not sure")
        XCTAssertEqual(rows[1][rows[0].firstIndex(of: "observation_description")!], "turtle", "the original stays its own column")

        let restored = InMemorySavedIdentificationRepository()
        _ = try await restored.importBackup(try DiveLogBackup.read(try export.json()))
        let back = await restored.fetchAll()
        XCTAssertEqual(back.first?.refinement, saved.refinement, "and through a JSON backup")
    }

    func testRecordsSavedBeforeRefinementDecodeWithoutOne() throws {
        let legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(SavedIdentification(fieldGuideSpecies:
            Species(id: UUID(), commonName: "A", scientificName: "a", summary: "", visualCharacteristics: [], habitat: "", geographicRange: "", imageAssetName: nil)))) as? [String: Any])
        var withoutKey = legacy
        withoutKey.removeValue(forKey: "refinement")
        let decoded = try JSONDecoder().decode(SavedIdentification.self, from: JSONSerialization.data(withJSONObject: withoutKey))
        XCTAssertNil(decoded.refinement)
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T { try XCTUnwrap(value, file: file, line: line) }
}
