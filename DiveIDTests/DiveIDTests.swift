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
        XCTAssertEqual(profiles.count, 10)
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
            ("Small blue fish with a yellow tail, about 20 cm, seen on a shallow reef in Fiji.", "Blue Tang", ["blue", "yellow", "reef", "fiji"]),
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
