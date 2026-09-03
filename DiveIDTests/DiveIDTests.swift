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

struct ResultsCatalogRepository: MarineSpeciesCatalogRepository {
    var metadata: [OfflineIdentificationPackMetadata]
    var error: (any Error)?

    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] {
        if let error { throw error }
        return metadata
    }

    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        throw LocalCatalogError.unsupportedPack
    }
}

actor MutableSelectedDiveRegionRepository: SelectedDiveRegionRepository {
    private var region: OfflineIdentificationPackID

    init(initialRegion: OfflineIdentificationPackID) { region = initialRegion }
    func selectedRegion() async -> OfflineIdentificationPackID { region }
    func setSelectedRegion(_ id: OfflineIdentificationPackID) async { region = id }
}

struct StubPhotoProcessingService: PhotoProcessingService {
    let photo: ProcessedPhoto
    func processPhotoData(_ data: Data) async throws -> ProcessedPhoto { photo }
}

final class DiveIDTests: XCTestCase {
    @MainActor
    func testResultsCopyUsesCaribbeanRequestMetadataAndSpeciesCount() async throws {
        let metadata = resultPackMetadata(id: .caribbean, displayName: "Caribbean", speciesCount: 78)
        let viewModel = try await loadedResultsViewModel(requestRegion: .caribbean, metadata: [metadata])

        XCTAssertEqual(viewModel.loadingMessage, "Searching the Caribbean offline pack…")
        XCTAssertEqual(viewModel.resultsSummary, "Matches from 78 locally stored Caribbean records")
    }

    @MainActor
    func testResultsCopyUsesSyntheticPackFromSubmittedRequest() async throws {
        let tropicalPacific = OfflineIdentificationPackID(rawValue: "tropical-pacific-test")
        let metadata = resultPackMetadata(id: tropicalPacific, displayName: "Tropical Pacific", speciesCount: 1_650)
        let viewModel = try await loadedResultsViewModel(requestRegion: tropicalPacific, metadata: [metadata])

        XCTAssertEqual(viewModel.loadingMessage, "Searching the Tropical Pacific offline pack…")
        XCTAssertEqual(viewModel.resultsSummary, "Matches from \(1_650.formatted()) locally stored Tropical Pacific records")
    }

    @MainActor
    func testReopenedResultsRemainTiedToSessionRegionWhenCurrentPreferenceChanges() async throws {
        let submittedRegion = OfflineIdentificationPackID(rawValue: "submitted-pack")
        let laterPreference = OfflineIdentificationPackID(rawValue: "later-preference")
        let submitted = resultPackMetadata(id: submittedRegion, displayName: "Submitted Region", speciesCount: 12)
        let later = resultPackMetadata(id: laterPreference, displayName: "Later Preference", speciesCount: 99)
        let preference = MutableSelectedDiveRegionRepository(initialRegion: submittedRegion)
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("striped fish"), context: .init(region: await preference.selectedRegion()))
        _ = try await store.createSession(for: request, photo: nil)
        let service = SpyMarineLifeIdentificationService(results: [makeMatch(score: 0.8)])
        let catalog = ResultsCatalogRepository(metadata: [later, submitted])
        let initialViewModel = IdentificationResultsViewModel(
            sessionID: request.id,
            service: service,
            sessionStore: store,
            catalog: catalog
        )

        await initialViewModel.loadIfNeeded()
        await preference.setSelectedRegion(laterPreference)
        let reopenedViewModel = IdentificationResultsViewModel(
            sessionID: request.id,
            service: service,
            sessionStore: store,
            catalog: catalog
        )

        await reopenedViewModel.loadIfNeeded()

        XCTAssertEqual(initialViewModel.resultsSummary, "Matches from 12 locally stored Submitted Region records")
        XCTAssertEqual(reopenedViewModel.loadingMessage, "Searching the Submitted Region offline pack…")
        XCTAssertEqual(reopenedViewModel.resultsSummary, "Matches from 12 locally stored Submitted Region records")
        XCTAssertFalse(reopenedViewModel.resultsSummary.contains("Later Preference"))
        let identificationCallCount = await service.callCount()
        XCTAssertEqual(identificationCallCount, 1)
    }

    @MainActor
    func testResultsMetadataFailureUsesGenericFallbackWithoutAnotherIdentification() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("striped fish"), context: .init(region: .caribbean))
        _ = try await store.createSession(for: request, photo: nil)
        let service = SpyMarineLifeIdentificationService(results: [makeMatch(score: 0.8)])
        let viewModel = IdentificationResultsViewModel(
            sessionID: request.id,
            service: service,
            sessionStore: store,
            catalog: ResultsCatalogRepository(metadata: [], error: LocalCatalogError.resourceMissing)
        )

        await viewModel.loadIfNeeded()

        XCTAssertEqual(viewModel.loadingMessage, "Searching the selected offline pack…")
        XCTAssertEqual(viewModel.resultsSummary, "Matches from the selected offline pack")
        let identificationCallCount = await service.callCount()
        XCTAssertEqual(identificationCallCount, 1)
        guard case .loaded = viewModel.state else { return XCTFail("Expected identification to remain loaded") }
    }

    func testActiveResultsCopyHasNoHardCodedCaribbeanText() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../DiveID/Features/IdentificationResults/IdentificationResults.swift")
            .standardizedFileURL
        let contents = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(contents.contains("Caribbean"))
    }

    @MainActor
    func testDescriptionCreatesSessionWithoutCallingServiceAndPreservesText() async throws {
        let store = InMemoryIdentificationSessionStore()
        let catalog = ResultsCatalogRepository(metadata: [
            resultPackMetadata(id: .caribbean, displayName: "Caribbean", speciesCount: 8)
        ])
        let regionRepository = MutableSelectedDiveRegionRepository(initialRegion: .caribbean)
        let viewModel = DescriptionSearchViewModel(
            sessionStore: store,
            catalog: catalog,
            regionRepository: regionRepository
        )
        viewModel.descriptionText = "  Blue fish, with spots!  "
        let submittedSessionID = await viewModel.submit()
        let sessionID = try XCTUnwrap(submittedSessionID)
        let request = try await store.request(for: sessionID)
        guard case .description(let description) = request.source else { return XCTFail("Expected description") }
        XCTAssertEqual(description, "Blue fish, with spots!")
        XCTAssertEqual(request.context.region, .caribbean)
    }

    @MainActor
    func testDescriptionRejectsWhitespace() {
        let catalog = ResultsCatalogRepository(metadata: [
            resultPackMetadata(id: .caribbean, displayName: "Caribbean", speciesCount: 8)
        ])
        let regionRepository = MutableSelectedDiveRegionRepository(initialRegion: .caribbean)
        let viewModel = DescriptionSearchViewModel(
            sessionStore: InMemoryIdentificationSessionStore(),
            catalog: catalog,
            regionRepository: regionRepository
        )
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
        let fetched = try await repository.fetchAll()
        XCTAssertEqual(fetched.count, 2)
        let recreated = try JSONSavedIdentificationRepository(fileURL: url)
        let firstSessionID = try XCTUnwrap(firstSaved.sourceSessionID)
        let recreatedSaved = try await recreated.savedIdentification(sourceSessionID: firstSessionID, speciesID: first.id)
        XCTAssertEqual(recreatedSaved?.id, firstSaved.id)
        try await recreated.remove(id: firstSaved.id)
        let final = try JSONSavedIdentificationRepository(fileURL: url)
        let finalSaved = try await final.fetchAll()
        XCTAssertEqual(finalSaved.map(\.species), [second])
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
    private func loadedResultsViewModel(
        requestRegion: OfflineIdentificationPackID,
        metadata: [OfflineIdentificationPackMetadata]
    ) async throws -> IdentificationResultsViewModel {
        let store = InMemoryIdentificationSessionStore()
        let request = IdentificationRequest(source: .description("striped fish"), context: .init(region: requestRegion))
        _ = try await store.createSession(for: request, photo: nil)
        let viewModel = IdentificationResultsViewModel(
            sessionID: request.id,
            service: SpyMarineLifeIdentificationService(results: [makeMatch(score: 0.8)]),
            sessionStore: store,
            catalog: ResultsCatalogRepository(metadata: metadata)
        )
        await viewModel.loadIfNeeded()
        return viewModel
    }

    private func resultPackMetadata(
        id: OfflineIdentificationPackID,
        displayName: String,
        speciesCount: Int
    ) -> OfflineIdentificationPackMetadata {
        OfflineIdentificationPackMetadata(
            id: id,
            schemaVersion: 1,
            packVersion: 1,
            displayName: displayName,
            shortDescription: "Test metadata",
            geographicScope: "Test scope",
            regionAliases: [],
            speciesCount: speciesCount,
            speciesResourceName: "TestSpecies",
            imageSubdirectory: "Images",
            includedWithApp: false,
            lastDataReviewDate: nil
        )
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
        let sourceSessionID = try XCTUnwrap(match.sourceSessionID)
        let savedIdentification = try await repository.savedIdentification(sourceSessionID: sourceSessionID, speciesID: match.species.id)
        XCTAssertEqual(savedIdentification?.id, savedID)
        await viewModel.toggleSaved()
        XCTAssertFalse(viewModel.isSaved)
        XCTAssertNil(viewModel.savedIdentificationID)
        let removedIdentification = try await repository.savedIdentification(sourceSessionID: sourceSessionID, speciesID: match.species.id)
        XCTAssertNil(removedIdentification)
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

    func testProductionCaribbeanPackLoadsAndValidates() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self))
        let manifests = try await repository.availablePacks()
        let manifest = try XCTUnwrap(manifests.first { $0.id == .caribbean })
        let pack: OfflineIdentificationPack
        do {
            pack = try await repository.loadPack(id: .caribbean)
        } catch {
            XCTFail("Production Caribbean pack failed to load: \(error)")
            return
        }
        XCTAssertEqual(manifest.speciesCount, 8)
        XCTAssertEqual(pack.metadata.id, .caribbean)
        XCTAssertEqual(pack.profiles.count, 8)
        XCTAssertEqual(pack.profiles.count, manifest.speciesCount)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(pack: pack, bundle: Bundle(for: Self.self)))
    }

    func testParserProducesNewCatalogueClues() async {
        let parsed = await parser.parse("A robust brown and olive fish")
        XCTAssertEqual(parsed.colors.intersection(["brown", "olive"]), ["brown", "olive"])
        XCTAssertTrue(parsed.bodyShapes.contains("robust"))
    }

    func testCatalogueAcceptsBrownOliveAndRobust() throws {
        var profile = try productionProfile(named: "Green Sea Turtle")
        profile.colors = ["brown", "olive"]
        profile.bodyShapes = ["robust"]
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([profile]))
    }

    func testCatalogueRejectsUnknownTopLevelColor() throws {
        var profile = try productionProfile(named: "Green Sea Turtle")
        profile.colors = ["ultraviolet"]
        assertUnknownVocabulary(profile, value: "ultraviolet")
    }

    func testCatalogueRejectsUnknownVariantColor() throws {
        var profile = try productionProfile(named: "Stoplight Parrotfish")
        profile.appearanceVariants = [variant(colors: ["ultraviolet"])]
        assertUnknownVocabulary(profile, value: "ultraviolet")
    }

    func testCatalogueRejectsUnknownVariantMarking() throws {
        var profile = try productionProfile(named: "Stoplight Parrotfish")
        profile.appearanceVariants = [variant(markings: ["chevrons"])]
        assertUnknownVocabulary(profile, value: "chevrons")
    }

    func testCatalogueRejectsUnknownVariantBodyShape() throws {
        var profile = try productionProfile(named: "Stoplight Parrotfish")
        profile.appearanceVariants = [variant(bodyShapes: ["cuboid"])]
        assertUnknownVocabulary(profile, value: "cuboid")
    }

    func testProductionStoplightParrotfishVariantPassesValidation() throws {
        let profile = try productionProfile(named: "Stoplight Parrotfish")
        XCTAssertEqual(profile.appearanceVariants.first?.colors, ["brown"])
        XCTAssertEqual(profile.appearanceVariants.first?.bodyShapes, ["robust"])
        XCTAssertTrue(profile.markings.contains("beak"))
        XCTAssertTrue(profile.behaviors.contains("grazing"))
        XCTAssertEqual(profile.mouthAndHeadShape, ["beak-like dental plates", "angular forehead", "squared head"])
        XCTAssertEqual(profile.review?.status, .draft)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([profile]))
    }

    func testProductionGreenSeaTurtlePassesValidation() throws {
        let profile = try productionProfile(named: "Green Sea Turtle")
        XCTAssertTrue(profile.colors.contains("brown"))
        XCTAssertTrue(profile.colors.contains("olive"))
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([profile]))
    }

    func testCatalogRepositoryCachesProductionPack() async throws {
        let repository = BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self))
        let first = try await repository.loadProfiles()
        let second = try await repository.loadProfiles()
        XCTAssertEqual(first, second)
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

    func testParserNormalizesParrotfishMorphologyAndGrazingTerms() async {
        for term in ["beak", "beaked", "beak-like"] {
            let parsed = await parser.parse("\(term) reef fish")
            XCTAssertTrue(parsed.markings.contains("beak"), term)
        }
        for term in ["grazer", "grazing", "graze"] {
            let parsed = await parser.parse("reef fish that will \(term)")
            XCTAssertTrue(parsed.behaviors.contains("grazing"), term)
            XCTAssertFalse(parsed.behaviors.contains("feeding"), term)
        }
        let squaredHead = await parser.parse("fish with a squared looking head")
        XCTAssertTrue(squaredHead.tokens.contains("squared head"))

        let unrelated = await parser.parse("silver fish feeding in open water")
        XCTAssertFalse(unrelated.markings.contains("beak"))
        XCTAssertFalse(unrelated.behaviors.contains("grazing"))
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
        let profiles = try await catalogProfiles()
        let cases: [(String, String, [String])] = [
            ("Blue oval surgeonfish, about 20 cm, seen on a shallow Caribbean reef.", "Atlantic Blue Tang", ["blue", "reef", "caribbean"]),
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

    func testStoplightParrotfishRanksForBeakGrazingAndSquaredHeadClues() async throws {
        let profiles = try await catalogProfiles()
        let stoplightID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let descriptions = [
            "beaked reef grazer with a squared looking head",
            "beaked grazing fish on a Caribbean reef",
            "parrot-like beak grazing coral reef"
        ]

        for description in descriptions {
            let observation = await parser.parse(description)
            let ranked = try await LocalSpeciesRanker().rank(observation: observation, profiles: profiles)
            let stoplightRank = ranked.firstIndex { $0.profile.id == stoplightID }.map { $0 + 1 }
            XCTAssertNotNil(stoplightRank, description)
            XCTAssertLessThanOrEqual(stoplightRank ?? .max, 3, description)
            XCTAssertTrue(ranked.first { $0.profile.id == stoplightID }?.matchedClues.contains("beak") == true, description)
            XCTAssertTrue(ranked.first { $0.profile.id == stoplightID }?.matchedClues.contains("grazing") == true, description)

            for candidate in ranked where candidate.profile.id != stoplightID {
                XCTAssertFalse(candidate.matchedClues.contains("beak"), "\(description): \(candidate.profile.commonName)")
                XCTAssertFalse(candidate.matchedClues.contains("grazing"), "\(description): \(candidate.profile.commonName)")
            }
        }
    }

    func testRankingInvariantsVagueAndUnrelatedDescriptions() async throws {
        let profiles = try await catalogProfiles()
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

    func testWeakDescriptionsDoNotProduceUsefulMatches() async throws {
        let profiles = try await catalogProfiles()
        let ranker = LocalSpeciesRanker()

        for description in ["dark shape", "blue thing", "fish", "small fish", "dark fish"] {
            let results = try await ranker.rank(observation: await parser.parse(description), profiles: profiles)
            XCTAssertTrue(results.isEmpty, description)
        }
    }

    func testRichDescriptionsAndExactNameStillProduceMatches() async throws {
        let service = LocalMarineLifeIdentificationService(
            catalogRepository: StaticCatalogRepository(profiles: try await catalogProfiles()),
            parser: parser,
            ranker: LocalSpeciesRanker()
        )
        let cases = [
            ("black flat ray with white spots over sand", "Spotted Eagle Ray"),
            ("long silver fish with big teeth", "Great Barracuda"),
            ("spotted eagle ray", "Spotted Eagle Ray")
        ]

        for (description, expectedName) in cases {
            let matches = try await service.identify(request: IdentificationRequest(source: .description(description)), processedPhoto: nil)
            XCTAssertEqual(matches.first?.species.commonName, expectedName, description)
        }
    }

    func testOccurrenceCannotCarryCandidateAcrossInclusionThreshold() async throws {
        let barracuda = try productionProfile(named: "Great Barracuda")
        let observation = await parser.parse("solitary turtle")

        let results = try await LocalSpeciesRanker().rank(observation: observation, profiles: [barracuda])

        XCTAssertTrue(results.isEmpty)
    }

    func testLocalServiceReturnsRelativeMatchesAndRejectsPhoto() async throws {
        let service = LocalMarineLifeIdentificationService(catalogRepository: StaticCatalogRepository(profiles: try await catalogProfiles()), parser: parser, ranker: LocalSpeciesRanker())
        let matches = try await service.identify(request: IdentificationRequest(source: .description("Long silver fish with large teeth swimming alone.")), processedPhoto: nil)
        XCTAssertEqual(matches.first?.species.commonName, "Great Barracuda")
        XCTAssertTrue(matches.allSatisfy { (0...1).contains($0.score) && $0.scoreKind == .relativeMatch && !$0.explanation.isEmpty })
        do {
            _ = try await service.identify(request: IdentificationRequest(source: .processedPhoto(ProcessedPhotoReference(id: UUID()))), processedPhoto: nil)
            XCTFail("Expected unsupported photo source")
        } catch { XCTAssertEqual(error as? LocalIdentificationError, .unsupportedSource) }
    }

    func testCaribbeanServiceRegionValidationUsesSharedCompatibility() async throws {
        let service = LocalMarineLifeIdentificationService(
            catalogRepository: BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self)),
            parser: parser,
            ranker: LocalSpeciesRanker()
        )
        let acceptedDescriptions = [
            "Caribbean reef",
            "Western Atlantic reef",
            "Atlantic reef",
            "Colorful reef fish",
            "Atlantis reef fish"
        ]

        for description in acceptedDescriptions {
            do {
                let matches = try await service.identify(
                    request: IdentificationRequest(source: .description(description), context: .init(region: .caribbean)),
                    processedPhoto: nil
                )
                XCTAssertFalse(matches.isEmpty, "Expected \(description) to reach ranking")
            } catch {
                XCTFail("Expected \(description) to pass regional validation, received \(error)")
            }
        }

        for description in ["Fiji reef", "Indo-Pacific reef"] {
            do {
                _ = try await service.identify(
                    request: IdentificationRequest(source: .description(description), context: .init(region: .caribbean)),
                    processedPhoto: nil
                )
                XCTFail("Expected \(description) to conflict with the Caribbean pack")
            } catch let error as LocalIdentificationError {
                guard case .regionMismatch(let selected, _) = error else {
                    return XCTFail("Expected region mismatch for \(description), received \(error)")
                }
                XCTAssertEqual(selected, .caribbean)
            }
        }
    }

    private func catalogProfiles() async throws -> [LocalSpeciesProfile] { try await BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self)).loadProfiles() }

    private func productionProfile(named name: String) throws -> LocalSpeciesProfile {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json").standardizedFileURL
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profiles = try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: url))
        return try XCTUnwrap(profiles.first { $0.commonName == name })
    }

    private func variant(colors: [String] = ["brown"], markings: [String] = ["spots"], bodyShapes: [String] = ["robust"]) -> SpeciesAppearanceVariant {
        SpeciesAppearanceVariant(id: "test-variant", lifeStage: .juvenile, colors: colors, markings: markings, bodyShapes: bodyShapes, minimumSizeCentimeters: 2, maximumSizeCentimeters: 30, description: "Test variant", distinguishingFeatures: ["Test feature"])
    }

    private func assertUnknownVocabulary(_ profile: LocalSpeciesProfile, value: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([profile]), file: file, line: line) {
            XCTAssertEqual($0 as? LocalCatalogError, .unknownControlledVocabularyValue(value), file: file, line: line)
        }
    }
}

struct StaticCatalogRepository: MarineSpeciesCatalogRepository {
    let profiles: [LocalSpeciesProfile]
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [] }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        OfflineIdentificationPack(metadata: OfflineIdentificationPackMetadata(id: id, schemaVersion: 1, packVersion: 1, displayName: "Test Pack", shortDescription: "Test", geographicScope: "Test", regionAliases: [], speciesCount: profiles.count, speciesResourceName: "TestSpecies", imageSubdirectory: "Images", includedWithApp: true, lastDataReviewDate: nil), profiles: profiles)
    }
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

    func testBoundaryAwareSynonymMatching() async {
        let grayFish = await parser.parse("gray fish")
        let predator = await parser.parse("predator cruising")
        let thousandFish = await parser.parse("thousand tiny fish")
        let eagleRay = await parser.parse("eagle ray over sandy bottom")
        let redFish = await parser.parse("red fish")
        let sandyBottom = await parser.parse("sandy bottom")
        XCTAssertFalse(grayFish.categories.contains("ray"))
        XCTAssertFalse(predator.colors.contains("red"))
        XCTAssertFalse(thousandFish.habitats.contains("sand"))
        XCTAssertTrue(eagleRay.categories.contains("ray"))
        XCTAssertTrue(redFish.colors.contains("red"))
        XCTAssertTrue(sandyBottom.habitats.contains("sand"))
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

    func testMeasurementRegressionPhrases() async {
        let cases: [(String, Double?, Double?)] = [
            ("around 2 m long", 200, nil),
            ("6 ft long", 182.88, nil),
            ("roughly 12 inches long", 30.48, nil),
            ("about 30 cm", 30, nil),
            ("about 20 m deep", nil, 20),
            ("around 60 feet deep", nil, 18.288),
            ("at 20 m", nil, 20),
            ("blue fish 20 meters from the boat", nil, nil),
            ("A 2 m long shark seen at 20 m deep.", 200, 20),
            ("A 6 ft long fish at 60 feet deep.", 182.88, 18.288)
        ]
        for (text, expectedSize, expectedDepth) in cases {
            let parsed = await parser.parse(text)
            XCTAssertEqual(parsed.approximateSizeCentimeters ?? -1, expectedSize ?? -1, accuracy: 0.01, text)
            XCTAssertEqual(parsed.approximateDepthMeters ?? -1, expectedDepth ?? -1, accuracy: 0.01, text)
        }
        let invalidDepth = await parser.parse("at 30 cm")
        XCTAssertNil(invalidDepth.approximateDepthMeters)
    }

    func testRegionCompatibilityResolver() {
        let resolver = RegionCompatibilityResolver()
        let cases: [(observed: Set<String>, supported: Set<String>, expected: RegionCompatibility)] = [
            ([], ["caribbean"], .unspecified),
            (["caribbean"], [], .unspecified),
            (["madeup place"], ["western atlantic"], .unspecified),
            (["caribbean"], ["caribbean"], .compatible),
            (["western atlantic"], ["caribbean"], .compatible),
            (["atlantic"], ["caribbean"], .compatible),
            (["caribbean"], ["atlantic"], .compatible),
            (["fiji"], ["indo-pacific"], .compatible),
            (["fiji"], ["western atlantic"], .conflicting),
            (["indo-pacific"], ["caribbean"], .conflicting)
        ]

        for testCase in cases {
            XCTAssertEqual(
                resolver.compatibility(observedRegions: testCase.observed, supportedRegions: testCase.supported),
                testCase.expected,
                "Observed \(testCase.observed) against supported \(testCase.supported)"
            )
        }
    }

    func testServiceAndRankerUseEquivalentSharedRegionCompatibility() {
        let service = LocalMarineLifeIdentificationService(
            catalogRepository: StaticCatalogRepository(profiles: []),
            parser: parser,
            ranker: LocalSpeciesRanker()
        )
        let ranker = LocalSpeciesRanker()
        let caribbeanPackRegions: Set<String> = ["caribbean"]
        let cases: [(observation: Set<String>, expected: RegionCompatibility)] = [
            (["caribbean"], .compatible),
            (["western atlantic"], .compatible),
            (["atlantic"], .compatible),
            ([], .unspecified),
            (["fiji"], .conflicting),
            (["indo-pacific"], .conflicting)
        ]

        for testCase in cases {
            let serviceResult = service.regionCompatibility(
                observedRegions: testCase.observation,
                supportedRegions: caribbeanPackRegions
            )
            let rankerResult = ranker.regionCompatibility(
                observedRegions: testCase.observation,
                supportedRegions: caribbeanPackRegions
            )

            XCTAssertEqual(serviceResult, testCase.expected, "Service observation: \(testCase.observation)")
            XCTAssertEqual(rankerResult, testCase.expected, "Ranker observation: \(testCase.observation)")
            XCTAssertEqual(serviceResult, rankerResult, "Observation: \(testCase.observation)")
        }
    }

    func testCatalogValidationRules() throws {
        let base = try productionCaribbeanProfiles().first!
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

    func testCatalogAcceptsProfileWithoutBundledArtworkAndMapsItToSpecies() throws {
        var profile = try productionCaribbeanProfiles().first!
        profile.bundledImage = nil

        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate([profile]))
        XCTAssertNil(profile.species.bundledImage)
        XCTAssertEqual(profile.species.id, profile.id)
        XCTAssertEqual(profile.species.commonName, profile.commonName)
    }

    @MainActor
    func testImageLessProfileRanksAndOpensInSpeciesDetail() async throws {
        var profile = try productionCaribbeanProfiles().first!
        profile.bundledImage = nil
        let observation = await parser.parse(profile.commonName)

        let matches = try await ranker.rank(observation: observation, profiles: [profile])

        let rankedProfile = try XCTUnwrap(matches.first?.profile)
        XCTAssertEqual(rankedProfile.id, profile.id)
        XCTAssertNil(rankedProfile.bundledImage)
        let viewModel = SpeciesDetailViewModel(species: rankedProfile.species, match: nil, repository: InMemorySavedIdentificationRepository())
        let detail = SpeciesDetailView(viewModel: viewModel)
        XCTAssertEqual(viewModel.species.id, profile.id)
        _ = detail.body
    }

    func testCatalogAcceptsValidApprovedBundledArtwork() throws {
        let profiles = try productionCaribbeanProfiles()
        let profile = try XCTUnwrap(profiles.first)

        XCTAssertNotNil(profile.bundledImage)
        XCTAssertNoThrow(try BundleMarineSpeciesCatalogRepository.validate(
            pack: OfflineIdentificationPack(metadata: try productionCaribbeanMetadata(speciesCount: profiles.count), profiles: profiles)
        ))
    }

    func testCatalogRejectsIncompleteOrUnsupportedArtworkAttribution() throws {
        let base = try productionCaribbeanProfiles().first!
        let valid = try XCTUnwrap(base.bundledImage)

        func profile(with image: BundledSpeciesImage) -> LocalSpeciesProfile {
            var profile = base
            profile.bundledImage = image
            return profile
        }
        func image(
            fileName: String? = nil,
            alternativeText: String? = nil,
            creatorName: String? = nil,
            sourceName: String? = nil,
            sourceURL: String? = nil,
            licenseName: String? = nil,
            licenseURL: String? = nil
        ) -> BundledSpeciesImage {
            BundledSpeciesImage(
                fileName: fileName ?? valid.fileName,
                alternativeText: alternativeText ?? valid.alternativeText,
                creatorName: creatorName ?? valid.creatorName,
                sourceName: sourceName ?? valid.sourceName,
                sourceURL: sourceURL ?? valid.sourceURL,
                licenseName: licenseName ?? valid.licenseName,
                licenseURL: licenseURL ?? valid.licenseURL
            )
        }
        func assertAttributionFailure(_ image: BundledSpeciesImage) {
            XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([profile(with: image)])) {
                XCTAssertEqual($0 as? LocalCatalogError, .emptyImageAttribution)
            }
        }

        assertAttributionFailure(image(alternativeText: ""))
        assertAttributionFailure(image(creatorName: ""))
        assertAttributionFailure(image(sourceName: ""))
        assertAttributionFailure(image(sourceURL: ""))
        assertAttributionFailure(image(licenseURL: ""))
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([profile(with: image(licenseName: ""))])) {
            XCTAssertEqual($0 as? LocalCatalogError, .unsupportedImageLicense(""))
        }
        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate([profile(with: image(licenseName: "All Rights Reserved"))])) {
            XCTAssertEqual($0 as? LocalCatalogError, .unsupportedImageLicense("All Rights Reserved"))
        }
    }

    func testCatalogRejectsMissingDeclaredArtworkFile() throws {
        var profile = try productionCaribbeanProfiles().first!
        let valid = try XCTUnwrap(profile.bundledImage)
        profile.bundledImage = BundledSpeciesImage(
            fileName: "not-in-the-pack.svg",
            alternativeText: valid.alternativeText,
            creatorName: valid.creatorName,
            sourceName: valid.sourceName,
            sourceURL: valid.sourceURL,
            licenseName: valid.licenseName,
            licenseURL: valid.licenseURL
        )

        XCTAssertThrowsError(try BundleMarineSpeciesCatalogRepository.validate(
            pack: OfflineIdentificationPack(metadata: try productionCaribbeanMetadata(speciesCount: 1), profiles: [profile])
        )) {
            XCTAssertEqual($0 as? LocalCatalogError, .missingImage(profile.id))
        }
    }

    func testManifestImageDirectoryLoadsArtwork() async throws {
        let profile = try productionCaribbeanProfiles().first!
        let image = try XCTUnwrap(profile.bundledImage)
        let loader = BundleSpeciesImageLoader(bundle: Bundle(for: Self.self))

        let data = try await loader.imageData(for: image, packID: .caribbean)

        XCTAssertFalse(data.isEmpty)
        XCTAssertTrue(String(decoding: data.prefix(100), as: UTF8.self).contains("<svg"))
    }

    @MainActor
    func testImageLessArtworkDoesNotRequestBundleFile() async throws {
        var profile = try productionCaribbeanProfiles().first!
        profile.bundledImage = nil
        let loader = CountingSpeciesImageLoader()

        let didLoad = await SpeciesArtwork.canLoadBundledArtwork(for: profile.species, using: loader)
        let requestCount = await loader.requestCount
        XCTAssertFalse(didLoad)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testImageLessSpeciesArtworkUsesAccessiblePlaceholder() throws {
        var profile = try productionCaribbeanProfiles().first!
        profile.bundledImage = nil

        let artwork = SpeciesArtwork(species: profile.species)
        XCTAssertTrue(artwork.showsPlaceholder)
        XCTAssertEqual(artwork.accessibilityDescription, "Placeholder image of \(profile.commonName)")
        _ = artwork.body
    }

    func testStructuredIdentificationQualityFixtures() async throws {
        let fixtures = qualityFixtures()
        let profiles = try await catalogProfiles()
        for fixture in fixtures {
            let observation = await parser.parse(fixture.description)
            let ranked = try await ranker.rank(observation: observation, profiles: profiles)
            if let region = fixture.expectedRegion { XCTAssertTrue(observation.regions.contains(region), fixture.notes) }
            if let expected = fixture.expectedSpeciesID {
                let ids = ranked.map(\.profile.id)
                switch fixture.requirement { case .top1: XCTAssertEqual(ids.first, expected, fixture.notes); case .top3: XCTAssertTrue(ids.prefix(3).contains(expected), fixture.notes); case .top10: XCTAssertTrue(ids.prefix(10).contains(expected), fixture.notes) }
            } else { XCTAssertTrue(ranked.isEmpty, fixture.notes) }
            XCTAssertTrue(fixture.mustNotRankSpeciesIDs.isDisjoint(with: Set(ranked.map(\.profile.id))), fixture.notes)
        }
    }

    private func qualityFixtures() -> [IdentificationQualityFixture] {[
        .init(description: "Large flat eagle ray with white spots and a long tail over sand", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!, expectedRegion: nil, requirement: .top1, notes: "clear ray clues", mustNotRankSpeciesIDs: []),
        .init(description: "blue tang in Caribbean reef", expectedSpeciesID: atlanticBlueTang, expectedRegion: "caribbean", requirement: .top1, notes: "regional blue tang", mustNotRankSpeciesIDs: []),
        .init(description: "red striped fish with venom spines hovering", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, expectedRegion: nil, requirement: .top1, notes: "lionfish", mustNotRankSpeciesIDs: []),
        .init(description: "green shell animal feeding in seagrass at 5 m", expectedSpeciesID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, expectedRegion: nil, requirement: .top1, notes: "size/depth compatible turtle", mustNotRankSpeciesIDs: []),
        .init(description: "brown dog on beach", expectedSpeciesID: nil, expectedRegion: nil, requirement: .top10, notes: "non-marine", mustNotRankSpeciesIDs: [])
    ] }

    private func catalogProfiles() async throws -> [LocalSpeciesProfile] { try await BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self)).loadProfiles() }
    private func productionCaribbeanProfiles() throws -> [LocalSpeciesProfile] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/IdentificationPacks/Caribbean/Creatures.json").standardizedFileURL
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([LocalSpeciesProfile].self, from: Data(contentsOf: url))
    }
    private func productionCaribbeanMetadata(speciesCount: Int) throws -> OfflineIdentificationPackMetadata {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../DiveID/Resources/IdentificationPacks/Caribbean/PackManifest.json").standardizedFileURL
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(OfflineIdentificationPackMetadata.self, from: Data(contentsOf: url))
        return OfflineIdentificationPackMetadata(id: value.id, schemaVersion: value.schemaVersion, packVersion: value.packVersion, displayName: value.displayName, shortDescription: value.shortDescription, geographicScope: value.geographicScope, regionAliases: value.regionAliases, speciesCount: speciesCount, speciesResourceName: value.speciesResourceName, imageSubdirectory: value.imageSubdirectory, includedWithApp: value.includedWithApp, lastDataReviewDate: value.lastDataReviewDate)
    }
    private func copy(_ p: LocalSpeciesProfile, id: UUID? = nil, commonName: String? = nil, scientificName: String? = nil, aliases: [String]? = nil, categories: [String]? = nil, colors: [String]? = nil, markings: [String]? = nil, bodyShapes: [String]? = nil, habitats: [String]? = nil, regions: [String]? = nil, behaviors: [String]? = nil, keywords: [String]? = nil, minimumSizeCentimeters: Double?? = nil, maximumSizeCentimeters: Double?? = nil, minimumDepthMeters: Double?? = nil, maximumDepthMeters: Double?? = nil, summary: String? = nil, distinguishingFeatures: [String]? = nil, typicalHabitat: String? = nil, geographicRange: String? = nil) -> LocalSpeciesProfile {
        LocalSpeciesProfile(id: id ?? p.id, commonName: commonName ?? p.commonName, scientificName: scientificName ?? p.scientificName, aliases: aliases ?? p.aliases, categories: categories ?? p.categories, colors: colors ?? p.colors, markings: markings ?? p.markings, bodyShapes: bodyShapes ?? p.bodyShapes, habitats: habitats ?? p.habitats, regions: regions ?? p.regions, behaviors: behaviors ?? p.behaviors, keywords: keywords ?? p.keywords, minimumSizeCentimeters: minimumSizeCentimeters ?? p.minimumSizeCentimeters, maximumSizeCentimeters: maximumSizeCentimeters ?? p.maximumSizeCentimeters, minimumDepthMeters: minimumDepthMeters ?? p.minimumDepthMeters, maximumDepthMeters: maximumDepthMeters ?? p.maximumDepthMeters, summary: summary ?? p.summary, distinguishingFeatures: distinguishingFeatures ?? p.distinguishingFeatures, typicalHabitat: typicalHabitat ?? p.typicalHabitat, geographicRange: geographicRange ?? p.geographicRange, cautions: p.cautions, imageAssetName: p.imageAssetName)
    }
}

private actor CountingSpeciesImageLoader: SpeciesImageLoading {
    private(set) var requestCount = 0
    func imageData(for image: BundledSpeciesImage, packID: OfflineIdentificationPackID) async throws -> Data {
        requestCount += 1
        return Data()
    }
}
