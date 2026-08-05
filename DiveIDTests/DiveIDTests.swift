import Foundation
import UIKit
import XCTest
@testable import DiveID

actor SpyMarineLifeIdentificationService: MarineLifeIdentificationService {
    private(set) var requests: [IdentificationRequest] = []
    private(set) var photos: [ProcessedPhoto?] = []
    var results: [IdentificationMatch]
    var error: (any Error)?

    init(results: [IdentificationMatch] = []) { self.results = results }

    func identify(request: IdentificationRequest, processedPhoto: ProcessedPhoto?) async throws -> [IdentificationMatch] {
        requests.append(request)
        photos.append(processedPhoto)
        if let error { throw error }
        return results
    }

    func callCount() -> Int { requests.count }
    func receivedRequests() -> [IdentificationRequest] { requests }
    func receivedPhotos() -> [ProcessedPhoto?] { photos }
    func setError(_ value: (any Error)?) { error = value }
    func setResults(_ value: [IdentificationMatch]) { results = value }
}

struct StubPhotoProcessingService: PhotoProcessingService {
    let photo: ProcessedPhoto
    func processPhotoData(_ data: Data) async throws -> ProcessedPhoto { photo }
}

final class DiveIDTests: XCTestCase {
    @MainActor
    func testDescriptionCreatesSessionWithoutCallingServiceAndPreservesText() async throws {
        let store = InMemoryIdentificationSessionStore()
        let viewModel = DescriptionSearchViewModel(sessionStore: store)
        viewModel.descriptionText = "  Blue fish, with spots!  "
        let submittedSessionID = await viewModel.submit()
        let sessionID = try XCTUnwrap(submittedSessionID)
        let request = try await store.request(for: sessionID)
        guard case .description(let description) = request.source else { return XCTFail("Expected description") }
        XCTAssertEqual(description, "Blue fish, with spots!")
    }

    @MainActor
    func testDescriptionRejectsWhitespace() {
        let viewModel = DescriptionSearchViewModel(sessionStore: InMemoryIdentificationSessionStore())
        viewModel.descriptionText = "  \n"
        XCTAssertFalse(viewModel.canSubmit)
    }

    @MainActor
    func testResultsExecuteExactlyOnceAndReuseSessionResult() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("yellow fish"))
        _ = try await store.createSession(for: request, photo: nil)
        let match = makeMatch(score: 0.9)
        let service = SpyMarineLifeIdentificationService(results: [match])
        let first = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await first.loadIfNeeded()
        await first.loadIfNeeded()
        let reopened = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await reopened.loadIfNeeded()
        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 1)
    }

    @MainActor
    func testPhotoBytesReachService() async throws {
        let store = InMemoryIdentificationSessionStore()
        let bytes = Data([2, 3, 4, 5])
        let photo = ProcessedPhoto(id: UUID(), previewData: Data([9]), uploadData: bytes, pixelWidth: 10, pixelHeight: 8, format: .jpeg)
        let request = IdentificationRequest(source: .processedPhoto(photo.reference))
        _ = try await store.createSession(for: request, photo: photo)
        let service = SpyMarineLifeIdentificationService(results: [makeMatch(score: 0.8)])
        let viewModel = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await viewModel.loadIfNeeded()
        let receivedPhoto = await service.receivedPhotos().first ?? nil
        XCTAssertEqual(receivedPhoto?.uploadData, bytes)
        XCTAssertNotEqual(bytes, Data([1]))
    }

    @MainActor
    func testRetryAddsOneCallAndClearsFailure() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("ray"))
        _ = try await store.createSession(for: request, photo: nil)
        let service = SpyMarineLifeIdentificationService()
        await service.setError(MockServiceError.demonstrationFailure)
        let viewModel = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await viewModel.loadIfNeeded()
        await service.setError(nil)
        await service.setResults([makeMatch(score: 0.7)])
        await viewModel.retry()
        let callCount = await service.callCount()
        XCTAssertEqual(callCount, 2)
        guard case .loaded = viewModel.state else { return XCTFail("Expected loaded state") }
    }

    @MainActor
    func testNewerPhotoSelectionWinsAndClearsError() async throws {
        let second = ProcessedPhoto(id: UUID(), previewData: Data([2]), uploadData: Data([22]), pixelWidth: 2, pixelHeight: 2, format: .jpeg)
        let viewModel = PhotoIdentificationViewModel(
            sessionStore: InMemoryIdentificationSessionStore(),
            photoProcessor: StubPhotoProcessingService(photo: second)
        )
        viewModel.selectionError = .unableToRead
        viewModel.selectPhoto { Data([22]) }
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(viewModel.processedPhoto, second)
        XCTAssertNil(viewModel.selectionError)
        XCTAssertFalse(viewModel.isLoadingSelection)
    }

    func testScoreBandBoundariesAndRelativeMockSemantics() async throws {
        XCTAssertEqual(MatchStrength.band(for: 0.85), .strong)
        XCTAssertEqual(MatchStrength.band(for: 0.65), .good)
        XCTAssertEqual(MatchStrength.band(for: 0.40), .possible)
        XCTAssertEqual(MatchStrength.band(for: 0.399), .weak)
        let request = IdentificationRequest(source: .description("fish"))
        let values = try await MockMarineLifeIdentificationService(delay: .zero).identify(request: request, processedPhoto: nil)
        XCTAssertTrue(values.allSatisfy { $0.scoreKind == .relativeMatch })
    }

    @MainActor
    func testResultsAreSortedLimitedAndEmptyIsNotFailure() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("fish"))
        _ = try await store.createSession(for: request, photo: nil)
        let scores = stride(from: 0.1, through: 1.2, by: 0.1).map { makeMatch(score: $0) }
        let service = SpyMarineLifeIdentificationService(results: scores)
        let viewModel = IdentificationResultsViewModel(sessionID: request.id, service: service, sessionStore: store)
        await viewModel.loadIfNeeded()
        guard case .loaded(let matches) = viewModel.state else { return XCTFail("Expected matches") }
        XCTAssertEqual(matches.count, 10)
        XCTAssertEqual(matches.map(\.score), matches.map(\.score).sorted(by: >))

        let emptyRequest = IdentificationRequest(source: .description("none"))
        _ = try await store.createSession(for: emptyRequest, photo: nil)
        let emptyViewModel = IdentificationResultsViewModel(
            sessionID: emptyRequest.id,
            service: SpyMarineLifeIdentificationService(),
            sessionStore: store
        )
        await emptyViewModel.loadIfNeeded()
        guard case .empty = emptyViewModel.state else { return XCTFail("Expected empty state") }
    }

    func testPhotoProcessingBoundsOutputDimensions() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3_000, height: 1_500))
        let input = renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 3_000, height: 1_500))
        }
        let processed = try await DefaultPhotoProcessingService().processPhotoData(input)
        XCTAssertLessThanOrEqual(max(processed.pixelWidth, processed.pixelHeight), DefaultPhotoProcessingService.uploadMaximumDimension)
        XCTAssertNotNil(UIImage(data: processed.previewData))
        XCTAssertNotNil(UIImage(data: processed.uploadData))
    }

    func testJSONRepositoryPersistsDeduplicatesAndRemoves() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.json")
        let first = MockSpecies.all[0]
        let second = MockSpecies.all[1]
        let repository = try JSONSavedIdentificationRepository(fileURL: url)
        var firstMatch = IdentificationMatch(id: first.id, species: first, score: 0.8, scoreKind: .relativeMatch); firstMatch.sourceSessionID = UUID()
        var secondMatch = IdentificationMatch(id: second.id, species: second, score: 0.7, scoreKind: .relativeMatch); secondMatch.sourceSessionID = UUID()
        let firstSaved = SavedIdentification(match: firstMatch); let secondSaved = SavedIdentification(match: secondMatch)
        _ = try await repository.save(firstSaved); _ = try await repository.save(firstSaved); _ = try await repository.save(secondSaved)
        XCTAssertEqual(try await repository.fetchAll().count, 2)
        let recreated = try JSONSavedIdentificationRepository(fileURL: url)
        let firstSessionID = try XCTUnwrap(firstSaved.sourceSessionID)
        XCTAssertEqual(try await recreated.savedIdentification(sourceSessionID: firstSessionID, speciesID: first.id)?.id, firstSaved.id)
        try await recreated.remove(id: firstSaved.id)
        let final = try JSONSavedIdentificationRepository(fileURL: url)
        XCTAssertEqual(try await final.fetchAll().map(\.species), [second])
    }

    func testCorruptPersistenceIsReportedWithoutOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("saved.json")
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: url)
        let repository = try JSONSavedIdentificationRepository(fileURL: url)
        let saved = SavedIdentification(match: IdentificationMatch(id: MockSpecies.all[0].id, species: MockSpecies.all[0], score: 0.5, scoreKind: .relativeMatch))
        do { _ = try await repository.save(saved); XCTFail("Expected corrupt data error") }
        catch { XCTAssertEqual(try Data(contentsOf: url), corrupt) }
    }

    @MainActor
    func testSaveThenRemoveWithoutLeavingDetail() async throws {
        let repository = InMemorySavedIdentificationRepository()
        var match = makeMatch(score: 0.8); match.sourceSessionID = UUID()
        let viewModel = SpeciesDetailViewModel(species: match.species, match: match, repository: repository)
        await viewModel.load()
        XCTAssertFalse(viewModel.isSaved)
        await viewModel.toggleSaved()
        let savedID = try XCTUnwrap(viewModel.savedIdentificationID)
        XCTAssertTrue(viewModel.isSaved)
        XCTAssertEqual(try await repository.savedIdentification(sourceSessionID: try XCTUnwrap(match.sourceSessionID), speciesID: match.species.id)?.id, savedID)
        await viewModel.toggleSaved()
        XCTAssertFalse(viewModel.isSaved)
        XCTAssertNil(viewModel.savedIdentificationID)
        XCTAssertNil(try await repository.savedIdentification(sourceSessionID: try XCTUnwrap(match.sourceSessionID), speciesID: match.species.id))
    }

    @MainActor
    func testSavedStateIsCandidateSpecificWithinSession() async throws {
        let repository = InMemorySavedIdentificationRepository()
        let session = UUID()
        var first = makeMatch(score: 0.9); first.sourceSessionID = session
        var second = IdentificationMatch(id: MockSpecies.all[1].id, species: MockSpecies.all[1], score: 0.7, scoreKind: .relativeMatch); second.sourceSessionID = session
        let firstViewModel = SpeciesDetailViewModel(species: first.species, match: first, repository: repository)
        await firstViewModel.toggleSaved()
        let secondViewModel = SpeciesDetailViewModel(species: second.species, match: second, repository: repository)
        await secondViewModel.load()
        XCTAssertFalse(secondViewModel.isSaved)
        await secondViewModel.toggleSaved()
        XCTAssertNotEqual(firstViewModel.savedIdentificationID, secondViewModel.savedIdentificationID)
        await firstViewModel.toggleSaved()
        XCTAssertTrue(secondViewModel.isSaved)
    }

    private func makeMatch(score: Double) -> IdentificationMatch {
        IdentificationMatch(id: MockSpecies.all[0].id, species: MockSpecies.all[0], score: score, scoreKind: .relativeMatch)
    }
}

final class LocalOfflineIdentificationTests: XCTestCase {
    private let parser = LocalObservationParser()

    func testCatalogJSONExistsAndDecodesWithValidProfiles() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/Data/MarineSpeciesCatalog.json").standardizedFileURL
        let data = try Data(contentsOf: url)
        let profiles = try JSONDecoder().decode([LocalSpeciesProfile].self, from: data)
        XCTAssertEqual(profiles.count, 11)
        XCTAssertEqual(Set(profiles.map(\.id)).count, profiles.count)
        XCTAssertEqual(Set(profiles.map { $0.scientificName.lowercased() }).count, profiles.count)
        XCTAssertTrue(profiles.allSatisfy { !$0.commonName.isEmpty && !$0.scientificName.isEmpty && !$0.distinguishingFeatures.isEmpty && !$0.typicalHabitat.isEmpty && !$0.geographicRange.isEmpty })
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(profiles))
    }

    func testCatalogRepositoryCachesAndReportsMissingOrInvalidResources() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/Data/MarineSpeciesCatalog.json").standardizedFileURL
        let target = directory.appendingPathComponent("MarineSpeciesCatalog.json")
        try Data(contentsOf: source).write(to: target)
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let repository = BundleMarineSpeciesCatalogRepository(bundle: bundle)
        let first = try await repository.loadProfiles()
        try Data("not json".utf8).write(to: target)
        let second = try await repository.loadProfiles()
        XCTAssertEqual(first, second)

        let missing = BundleMarineSpeciesCatalogRepository(bundle: bundle, resourceName: "MissingCatalog")
        do { _ = try await missing.loadProfiles(); XCTFail("Expected missing resource") }
        catch { XCTAssertEqual(error as? LocalCatalogError, .resourceMissing) }

        let invalid = BundleMarineSpeciesCatalogRepository(bundle: bundle)
        do { _ = try await invalid.loadProfiles(); XCTFail("Expected invalid JSON") }
        catch { XCTAssertEqual(error as? LocalCatalogError, .invalidData) }
    }

    func testCatalogValidationRejectsDuplicates() throws {
        let profile = MockSpecies.all[0]
        let local = LocalSpeciesProfile(id: profile.id, commonName: profile.commonName, scientificName: profile.scientificName, aliases: [], categories: ["fish"], colors: ["yellow"], markings: [], bodyShapes: [], habitats: ["reef"], regions: [], behaviors: [], keywords: [], minimumSizeCentimeters: nil, maximumSizeCentimeters: nil, minimumDepthMeters: nil, maximumDepthMeters: nil, summary: profile.summary, distinguishingFeatures: profile.visualCharacteristics, typicalHabitat: profile.habitat, geographicRange: profile.geographicRange, cautions: [], imageAssetName: nil)
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([local, local])) { XCTAssertEqual($0 as? LocalCatalogError, .duplicateIdentifier) }
        var other = local
        other = LocalSpeciesProfile(id: UUID(), commonName: "Other", scientificName: local.scientificName, aliases: [], categories: [], colors: [], markings: [], bodyShapes: [], habitats: [], regions: [], behaviors: [], keywords: [], minimumSizeCentimeters: nil, maximumSizeCentimeters: nil, minimumDepthMeters: nil, maximumDepthMeters: nil, summary: "", distinguishingFeatures: ["feature"], typicalHabitat: "habitat", geographicRange: "range", cautions: [], imageAssetName: nil)
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([local, other])) { XCTAssertEqual($0 as? LocalCatalogError, .duplicateScientificName) }
    }

    func testParserCoversSynonymsMeasurementsDepthRegionsAndBehaviors() async {
        let parsed = await parser.parse("Small BLUE fish, dotted and striped, 20cm at 5 m deep on coral reef in Fiji, hovering near sand.")
        XCTAssertTrue(parsed.colors.contains("blue"))
        XCTAssertTrue(parsed.markings.contains("spots"))
        XCTAssertTrue(parsed.markings.contains("stripes"))
        XCTAssertTrue(parsed.habitats.contains("reef"))
        XCTAssertTrue(parsed.regions.contains("fiji"))
        XCTAssertTrue(parsed.behaviors.contains("hovering"))
        XCTAssertEqual(parsed.approximateSizeCentimeters, 20)
        XCTAssertEqual(parsed.approximateDepthMeters, 5)
        XCTAssertTrue(parsed.tokens.contains("20cm") || parsed.normalizedText.contains("20cm"))
    }

    func testParserTextSizesAndNonMarineInput() async {
        let halfMeter = await parser.parse("half a meter large turtle in shallow water")
        XCTAssertEqual(halfMeter.approximateSizeCentimeters, 50)
        XCTAssertEqual(halfMeter.approximateDepthMeters, 3)
        XCTAssertTrue(halfMeter.categories.contains("turtle"))
        let unrelated = await parser.parse("A red bird sitting in a tree")
        XCTAssertTrue(unrelated.categories.isEmpty)
    }

    func testRealisticDescriptionsRankExpectedSpeciesFirst() async throws {
        let profiles = try catalogProfiles()
        let cases: [(String, String, [String])] = [
            ("Small blue fish with a yellow tail, about 20 cm, seen on a shallow reef in Fiji.", "Palette Surgeonfish", ["blue", "yellow", "reef", "fiji"]),
            ("Striped red and white fish with long spines, hovering near a reef wall.", "Red Lionfish", ["stripes", "spines"]),
            ("Large turtle with a smooth shell feeding on seagrass in shallow water.", "Green Sea Turtle", ["turtle", "shell", "seagrass"]),
            ("Large flat ray with white spots and a long thin tail swimming above sand.", "Spotted Eagle Ray", ["flat", "spots", "tail"]),
            ("Long silver fish with a pointed head and large teeth swimming alone.", "Great Barracuda", ["silver", "pointed", "teeth"])
        ]
        for item in cases {
            let observation = await parser.parse(item.0)
            let ranked = try await LocalSpeciesRanker().rank(observation: observation, profiles: profiles)
            XCTAssertEqual(ranked.first?.profile.commonName, item.1)
            XCTAssertTrue(item.2.contains { ranked.first?.matchedClues.contains($0) == true })
        }
    }

    func testRankingInvariantsVagueAndUnrelatedDescriptions() async throws {
        let profiles = try catalogProfiles()
        let ranker = LocalSpeciesRanker()
        let vague = try await ranker.rank(observation: await parser.parse("A fish on the reef."), profiles: profiles)
        XCTAssertFalse(vague.isEmpty)
        XCTAssertTrue(vague.allSatisfy { $0.score < 0.65 })
        XCTAssertEqual(vague.map(\.score), vague.map(\.score).sorted(by: >))
        XCTAssertLessThanOrEqual(vague.count, 10)
        let repeatVague = try await ranker.rank(observation: await parser.parse("A fish on the reef."), profiles: profiles)
        XCTAssertEqual(vague.map { $0.profile.id }, repeatVague.map { $0.profile.id })
        let unrelated = try await ranker.rank(observation: await parser.parse("A red bird sitting in a tree."), profiles: profiles)
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testLocalServiceReturnsRelativeMatchesAndRejectsPhoto() async throws {
        let service = LocalMarineLifeIdentificationService(catalogRepository: StaticCatalogRepository(profiles: try catalogProfiles()), parser: parser, ranker: LocalSpeciesRanker())
        let matches = try await service.identify(request: IdentificationRequest(source: .description("Long silver fish with large teeth swimming alone.")), processedPhoto: nil)
        XCTAssertEqual(matches.first?.species.commonName, "Great Barracuda")
        XCTAssertTrue(matches.allSatisfy { (0...1).contains($0.score) && $0.scoreKind == .relativeMatch && !$0.explanation.isEmpty })
        do {
            _ = try await service.identify(request: IdentificationRequest(source: .processedPhoto(ProcessedPhotoReference(id: UUID()))), processedPhoto: nil)
            XCTFail("Expected unsupported photo source")
        } catch { XCTAssertEqual(error as? LocalIdentificationError, .unsupportedSource) }
    }

    private func catalogProfiles() throws -> [LocalSpeciesProfile] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/Data/MarineSpeciesCatalog.json").standardizedFileURL
        return try JSONDecoder().decode([LocalSpeciesProfile].self, from: Data(contentsOf: url))
    }
}

struct StaticCatalogRepository: MarineSpeciesCatalogRepository {
    let profiles: [LocalSpeciesProfile]
    func loadProfiles() async throws -> [LocalSpeciesProfile] { profiles }
}

struct IdentificationQualityFixture {
    enum Requirement { case top1, top3, top10 }
    let description: String
    let expectedSpeciesID: UUID?
    let expectedRegion: String?
    let requirement: Requirement
    let notes: String
    let mustNotRankSpeciesIDs: Set<UUID>
}

final class OfflineCatalogHardeningTests: XCTestCase {
    let parser = LocalObservationParser()
    let ranker = LocalSpeciesRanker()
    let atlanticBlueTang = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let paletteSurgeonfish = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!

    func testBlueTangSpeciesAreSeparateAndRankByRegion() async throws {
        let profiles = try catalogProfiles()
        let atlantic = try await ranker.rank(observation: await parser.parse("Adult blue tang surgeonfish on a Caribbean reef in the western Atlantic around 15 m deep."), profiles: profiles)
        XCTAssertEqual(atlantic.first?.profile.id, atlanticBlueTang)
        let fiji = try await ranker.rank(observation: await parser.parse("Bright blue Indo-Pacific fish in Fiji with a black marking and yellow tail on a coral reef."), profiles: profiles)
        XCTAssertEqual(fiji.first?.profile.id, paletteSurgeonfish)
        let atlanticProfile = profiles.first { $0.id == atlanticBlueTang }
        let paletteProfile = profiles.first { $0.id == paletteSurgeonfish }
        XCTAssertNotEqual(atlanticProfile?.scientificName, paletteProfile?.scientificName)
        XCTAssertFalse(atlanticProfile?.aliases.contains(paletteProfile?.scientificName ?? "") ?? true)
    }

    func testBoundaryAwareSynonymMatching() async {
        XCTAssertFalse(await parser.parse("gray fish").categories.contains("ray"))
        XCTAssertFalse(await parser.parse("predator cruising").colors.contains("red"))
        XCTAssertFalse(await parser.parse("thousand tiny fish").habitats.contains("sand"))
        XCTAssertTrue(await parser.parse("eagle ray over sandy bottom").categories.contains("ray"))
        XCTAssertTrue(await parser.parse("red fish").colors.contains("red"))
        XCTAssertTrue(await parser.parse("sandy bottom").habitats.contains("sand"))
    }

    func testMeasurementParsingDisambiguatesDepthAndSize() async {
        let depthCases = ["at 20 m", "20 m deep", "depth of 20 meters", "around 60 feet deep"]
        let expectedDepths = [20.0, 20.0, 20.0, 18.288]
        for (text, expected) in zip(depthCases, expectedDepths) {
            let parsed = await parser.parse("blue fish " + text)
            XCTAssertNil(parsed.approximateSizeCentimeters)
            XCTAssertEqual(parsed.approximateDepthMeters!, expected, accuracy: 0.01)
        }
        let sizeCases = ["2 m long", "length about 2 meters", "about 30 cm", "roughly 12 inches long"]
        let expectedSizes = [200.0, 200.0, 30.0, 30.48]
        for (text, expected) in zip(sizeCases, expectedSizes) {
            let parsed = await parser.parse("blue fish " + text)
            XCTAssertEqual(parsed.approximateSizeCentimeters!, expected, accuracy: 0.01)
            XCTAssertNil(parsed.approximateDepthMeters)
        }
        let ambiguous = await parser.parse("blue fish 20 meters from the boat")
        XCTAssertNil(ambiguous.approximateSizeCentimeters)
        XCTAssertNil(ambiguous.approximateDepthMeters)
    }

    func testCatalogValidationRules() throws {
        let base = try catalogProfiles().first!
        func check(_ p: LocalSpeciesProfile, _ error: LocalCatalogError) { XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([p])) { XCTAssertEqual($0 as? LocalCatalogError, error) } }
        check(copy(base, commonName: " "), .emptyCommonName)
        check(copy(base, scientificName: " "), .emptyScientificName)
        check(copy(base, summary: ""), .emptySummary)
        check(copy(base, distinguishingFeatures: []), .emptyDistinguishingFeatures)
        check(copy(base, typicalHabitat: ""), .emptyHabitatDescription)
        check(copy(base, geographicRange: ""), .emptyGeographicRange)
        check(copy(base, minimumSizeCentimeters: -1), .negativeMeasurement)
        check(copy(base, minimumDepthMeters: 10, maximumDepthMeters: 1), .invalidMeasurementRange)
        check(copy(base, colors: ["purple"]), .unknownControlledVocabularyValue("purple"))
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([base, copy(base)])) { XCTAssertEqual($0 as? LocalCatalogError, .duplicateIdentifier) }
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([base, copy(base, id: UUID(), commonName: "Other")])) { XCTAssertEqual($0 as? LocalCatalogError, .duplicateScientificName) }
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([base, copy(base, id: UUID(), commonName: "Other", scientificName: "Other scientific", aliases: [base.commonName])])) { XCTAssertEqual($0 as? LocalCatalogError, .aliasCollidesWithCanonicalIdentity) }
    }

    func testStructuredIdentificationQualityFixtures() async throws {
        let fixtures = qualityFixtures()
        let profiles = try catalogProfiles()
        for fixture in fixtures {
            let ranked = try await ranker.rank(observation: await parser.parse(fixture.description), profiles: profiles)
            if let region = fixture.expectedRegion { XCTAssertTrue((await parser.parse(fixture.description)).regions.contains(region), fixture.notes) }
            if let expected = fixture.expectedSpeciesID {
                let ids = ranked.map(\.profile.id)
                switch fixture.requirement { case .top1: XCTAssertEqual(ids.first, expected, fixture.notes); case .top3: XCTAssertTrue(ids.prefix(3).contains(expected), fixture.notes); case .top10: XCTAssertTrue(ids.prefix(10).contains(expected), fixture.notes) }
            } else { XCTAssertTrue(ranked.isEmpty, fixture.notes) }
            XCTAssertTrue(fixture.mustNotRankSpeciesIDs.isDisjoint(with: Set(ranked.map(\.profile.id))), fixture.notes)
        }
    }

    private func qualityFixtures() -> [IdentificationQualityFixture] {[
        .init(description: "Large flat eagle ray with white spots and a long tail over sand", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, expectedRegion: nil, requirement: .top1, notes: "clear ray clues", mustNotRankSpeciesIDs: []),
        .init(description: "fish on reef", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, expectedRegion: nil, requirement: .top10, notes: "vague fish remains deterministic", mustNotRankSpeciesIDs: []),
        .init(description: "yelow disk fish in hawaii lagoon", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, expectedRegion: "hawaii", requirement: .top3, notes: "misspelling plus shape and region", mustNotRankSpeciesIDs: []),
        .init(description: "blue tang in Caribbean reef", expectedSpeciesID: atlanticBlueTang, expectedRegion: "caribbean", requirement: .top1, notes: "regional blue tang", mustNotRankSpeciesIDs: [paletteSurgeonfish]),
        .init(description: "blue fish yellow tail Fiji reef", expectedSpeciesID: paletteSurgeonfish, expectedRegion: "fiji", requirement: .top1, notes: "Fiji yellow tail", mustNotRankSpeciesIDs: [atlanticBlueTang]),
        .init(description: "red striped fish with venom spines hovering", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, expectedRegion: nil, requirement: .top1, notes: "lionfish", mustNotRankSpeciesIDs: []),
        .init(description: "green shell animal feeding in seagrass at 5 m", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, expectedRegion: nil, requirement: .top1, notes: "size/depth compatible turtle", mustNotRankSpeciesIDs: []),
        .init(description: "brown dog on beach", expectedSpeciesID: nil, expectedRegion: nil, requirement: .top10, notes: "non-marine", mustNotRankSpeciesIDs: [])
    ] }

    private func catalogProfiles() throws -> [LocalSpeciesProfile] { try JSONDecoder().decode([LocalSpeciesProfile].self, from: Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/Data/MarineSpeciesCatalog.json").standardizedFileURL)) }
    private func copy(_ p: LocalSpeciesProfile, id: UUID? = nil, commonName: String? = nil, scientificName: String? = nil, aliases: [String]? = nil, categories: [String]? = nil, colors: [String]? = nil, markings: [String]? = nil, bodyShapes: [String]? = nil, habitats: [String]? = nil, regions: [String]? = nil, behaviors: [String]? = nil, keywords: [String]? = nil, minimumSizeCentimeters: Double?? = nil, maximumSizeCentimeters: Double?? = nil, minimumDepthMeters: Double?? = nil, maximumDepthMeters: Double?? = nil, summary: String? = nil, distinguishingFeatures: [String]? = nil, typicalHabitat: String? = nil, geographicRange: String? = nil) -> LocalSpeciesProfile {
        LocalSpeciesProfile(id: id ?? p.id, commonName: commonName ?? p.commonName, scientificName: scientificName ?? p.scientificName, aliases: aliases ?? p.aliases, categories: categories ?? p.categories, colors: colors ?? p.colors, markings: markings ?? p.markings, bodyShapes: bodyShapes ?? p.bodyShapes, habitats: habitats ?? p.habitats, regions: regions ?? p.regions, behaviors: behaviors ?? p.behaviors, keywords: keywords ?? p.keywords, minimumSizeCentimeters: minimumSizeCentimeters ?? p.minimumSizeCentimeters, maximumSizeCentimeters: maximumSizeCentimeters ?? p.maximumSizeCentimeters, minimumDepthMeters: minimumDepthMeters ?? p.minimumDepthMeters, maximumDepthMeters: maximumDepthMeters ?? p.maximumDepthMeters, summary: summary ?? p.summary, distinguishingFeatures: distinguishingFeatures ?? p.distinguishingFeatures, typicalHabitat: typicalHabitat ?? p.typicalHabitat, geographicRange: geographicRange ?? p.geographicRange, cautions: p.cautions, imageAssetName: p.imageAssetName)
    }
}
