import XCTest
@testable import DiveID

/// Photo identification with the test recognizer (Docs/HybridRankingContract.md#photo-evidence).
final class PhotoIdentificationTests: XCTestCase {
    private let photo = ProcessedPhoto(id: UUID(), previewData: Data([1]), uploadData: Data([1, 2, 3]), pixelWidth: 64, pixelHeight: 64, format: .jpeg)
    private let debug = FeatureAvailability.forChannel(.debug)
    private let release = FeatureAvailability.forChannel(.release)

    private func repository(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess = .experimentalDevelopment) -> BundleMarineSpeciesCatalogRepository {
#if SWIFT_PACKAGE
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource, access: access)
#else
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access)
#endif
    }

    private func caribbean() async throws -> OfflineIdentificationPack { try await repository().loadPack(id: .caribbean) }

    private func candidate(_ id: UUID, _ similarity: Double, scale: PhotoSimilarityScale = .unitInterval) -> PhotoRecognitionCandidate {
        PhotoRecognitionCandidate(speciesID: id, similarity: .init(value: similarity, scale: scale), evidence: .init(referenceID: "ref-\(id.uuidString)"))
    }

    private func stub(_ candidates: [PhotoRecognitionCandidate], abstained: Bool = false, covering: Set<UUID>? = nil,
                      delay: Duration = .zero, calls: CallCounter? = nil) -> StubPhotoRecognizer {
        StubPhotoRecognizer(coveredSpeciesIDs: covering ?? Set(candidates.map(\.speciesID)), delay: delay) { _ in
            calls?.increment()
            return PhotoRecognition(candidates: candidates, abstained: abstained)
        }
    }

    private struct Provider: PhotoRecognizerProviding {
        let recognizer: StubPhotoRecognizer
        func recognizer(for pack: OfflineIdentificationPack) async throws -> (any PhotoRecognizer)? { recognizer }
    }

    private func photoService(_ recognizer: StubPhotoRecognizer) -> PhotoIdentificationService {
        PhotoIdentificationService(recognizers: Provider(recognizer: recognizer),
                                   searchEngine: HybridDescriptionSearchEngine(parser: LocalObservationParser(), ranker: LocalSpeciesRanker()))
    }

    private func identificationService(_ recognizer: StubPhotoRecognizer, features: FeatureAvailability,
                                       access: BundleMarineSpeciesCatalogRepository.CatalogueAccess = .experimentalDevelopment) -> LocalMarineLifeIdentificationService {
        LocalMarineLifeIdentificationService(catalogRepository: repository(access), photoIdentification: photoService(recognizer), features: features)
    }

    private func photoRequest(_ region: OfflineIdentificationPackID = .caribbean, notes: String? = nil) -> IdentificationRequest {
        IdentificationRequest(source: .processedPhoto(photo.reference), context: .init(region: region, additionalDescription: notes))
    }

    // MARK: Ranking and filtering

    func testPhotoOnlyResultsAreOrderedFilteredAndNeverAboveLimitedConfidence() async throws {
        let pack = try await caribbean()
        let ids = pack.profiles.map(\.id)
        let outside = UUID()
        let recognition = PhotoRecognition(candidates: [
            candidate(ids[2], 0.70), candidate(outside, 0.99), candidate(ids[0], 0.97), candidate(ids[1], 0.4), candidate(ids[3], 0.97),
        ])
        let result = PhotoEvidenceFusion.fuse(recognition: recognition, text: nil, pack: pack)
        XCTAssertFalse(result.photoAbstained)
        let tied = [ids[0], ids[3]].sorted { first, second in
            let a = pack.profiles.first { $0.id == first }!.commonName, b = pack.profiles.first { $0.id == second }!.commonName
            return a.localizedStandardCompare(b) == .orderedAscending
        }
        XCTAssertEqual(result.matches.map(\.species.id), tied + [ids[2]], "outside the pack and below the threshold are dropped; ties by name")
        XCTAssertEqual(result.matches.map(\.rank), [1, 2, 3])
        for match in result.matches {
            XCTAssertLessThanOrEqual(match.score, LocalRankingWeights.limitedConfidenceCap, "a photo alone never shows more than limited confidence")
            XCTAssertEqual(match.informationLevel, .limited)
            XCTAssertEqual(match.matchStrength, .possible)
            XCTAssertEqual(match.explanation, PhotoMatchingWeights.explanation)
            XCTAssertEqual(match.photoEvidence?.referenceID, "ref-\(match.species.id.uuidString)")
            XCTAssertEqual(match.packContext?.packID, .caribbean)
        }
    }

    func testCosineSimilaritiesAreNormalizedBeforeUse() {
        XCTAssertEqual(PhotoSimilarity(value: 1, scale: .cosine).normalized, 1)
        XCTAssertEqual(PhotoSimilarity(value: 0, scale: .cosine).normalized, 0.5)
        XCTAssertEqual(PhotoSimilarity(value: -2, scale: .cosine).normalized, 0)
        XCTAssertEqual(PhotoSimilarity(value: 1.4, scale: .unitInterval).normalized, 1)
        XCTAssertEqual(PhotoSimilarity(value: .nan, scale: .unitInterval).normalized, 0)
    }

    /// Returns a pack with only some records, as publication access returns the approved subset.
    private struct SubsetCatalog: MarineSpeciesCatalogRepository {
        let pack: OfflineIdentificationPack
        func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
        func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { pack }
    }

    func testPhotoCandidatesAreLimitedToThePackTheCatalogueReturns() async throws {
        // No bundled pack is partly approved (Global is fully approved, Caribbean has no
        // publishable pack), so this stands in for Release's approved subset.
        let full = try await caribbean()
        let approved = Array(full.profiles.prefix(2))
        var metadata = full.metadata
        metadata.speciesCount = approved.count
        let subset = OfflineIdentificationPack(metadata: metadata, profiles: approved)
        let draft = full.profiles[5]
        let service = LocalMarineLifeIdentificationService(
            catalogRepository: SubsetCatalog(pack: subset),
            photoIdentification: photoService(stub([candidate(draft.id, 0.95), candidate(approved[1].id, 0.9)])), features: debug)
        let outcome = try await service.identifyOutcome(request: photoRequest(), processedPhoto: photo)
        XCTAssertEqual(outcome.matches.map(\.species.id), [approved[1].id], "a record the catalogue didn't return never appears")
        XCTAssertEqual(outcome.photoSummary?.catalogueSpeciesCount, 2)
        XCTAssertEqual(outcome.photoSummary?.coveredSpeciesCount, 1)
    }

    // MARK: Abstaining

    func testLowTopScoreAbstains() async throws {
        let pack = try await caribbean()
        let low = PhotoMatchingWeights.abstainSimilarity - 0.01
        let result = PhotoEvidenceFusion.fuse(recognition: PhotoRecognition(candidates: [candidate(pack.profiles[0].id, low)]), text: nil, pack: pack)
        XCTAssertTrue(result.photoAbstained)
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testRecognizerAbstentionWinsOverHighScores() async throws {
        let pack = try await caribbean()
        let outcome = try await identificationService(stub([candidate(pack.profiles[0].id, 0.99)], abstained: true), features: debug)
            .identifyOutcome(request: photoRequest(), processedPhoto: photo)
        XCTAssertTrue(outcome.matches.isEmpty)
        XCTAssertEqual(outcome.photoSummary?.abstained, true)
        XCTAssertEqual(outcome.photoSummary?.isPlaceholder, true)
    }

    @MainActor
    func testResultsScreenShowsNoConfidentPhotoMatch() async throws {
        let store = InMemoryIdentificationSessionStore()
        let request = photoRequest()
        _ = try await store.createSession(for: request, photo: photo)
        let model = IdentificationResultsViewModel(sessionID: request.id, service: identificationService(stub([]), features: debug),
                                                   sessionStore: store, catalog: repository())
        await model.loadIfNeeded()
        guard case .empty = model.state else { return XCTFail("expected no results, got \(model.state)") }
        XCTAssertTrue(model.isPhotoAbstention)
        XCTAssertTrue(model.isPhotoSearch)
    }

    // MARK: Cancellation

    func testCancellingStopsTheRecognizer() async throws {
        let pack = try await caribbean()
        let service = identificationService(stub([candidate(pack.profiles[0].id, 0.9)], delay: .seconds(30)), features: debug)
        let request = photoRequest(), photo = self.photo
        let task = Task { try await service.identifyOutcome(request: request, processedPhoto: photo) }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testRecognizerRunsOffTheMainActor() async throws {
        let onMain = try await PhotoIdentificationService.offMainActor { pthread_main_np() != 0 }
        XCTAssertFalse(onMain)
    }

    // MARK: Release exclusion

    func testReleaseCannotReachPhotoRecognition() async throws {
        let pack = try await caribbean()
        let calls = CallCounter()
        let service = identificationService(stub([candidate(pack.profiles[0].id, 0.9)], calls: calls), features: release)
        do {
            _ = try await service.identifyOutcome(request: photoRequest(), processedPhoto: photo)
            XCTFail("Release must not run photo recognition")
        } catch {
            XCTAssertEqual(error as? LocalIdentificationError, .unsupportedSource)
        }
        XCTAssertEqual(calls.value, 0, "the recognizer never ran")
        XCTAssertNil(PhotoIdentificationService.forApp(features: release, searchEngine: HybridDescriptionSearchEngine(),
                                                       recognizers: StubPhotoRecognizerProvider()))
        XCTAssertFalse(release.photoIdentificationEnabled)
        XCTAssertTrue(FeatureAvailability.forChannel(.internal).photoIdentificationEnabled)
        XCTAssertTrue(debug.photoIdentificationEnabled)
    }

    @MainActor
    func testReleaseRouterDropsAProgrammaticPhotoRoute() {
        let router = AppRouter(features: release)
        router.navigate(to: .photoIdentification)
        XCTAssertTrue(router.path.isEmpty)
        router.path = [.savedIdentifications, .photoIdentification]
        XCTAssertEqual(router.path, [.savedIdentifications])

        let development = AppRouter(features: debug)
        development.navigate(to: .photoIdentification)
        XCTAssertEqual(development.path, [.photoIdentification])
    }

    // MARK: Fusion with text

    func testPhotoReordersDescriptionResultsButNeverRaisesTheirConfidence() async throws {
        let pack = try await caribbean()
        let description = "Large flat eagle ray with white spots and a long tail over sand in the Caribbean."
        let text = try await HybridDescriptionSearchEngine(parser: LocalObservationParser(), ranker: LocalSpeciesRanker())
            .search(description: description, pack: pack)
        let ranked = text.candidates
        XCTAssertGreaterThanOrEqual(ranked.count, 1)
        let textScores = Dictionary(uniqueKeysWithValues: ranked.map { ($0.profile.id, $0.score) })
        let unranked = try XCTUnwrap(pack.profiles.first { textScores[$0.id] == nil })
        var photoCandidates = [candidate(unranked.id, 0.99)]
        if let last = ranked.last { photoCandidates.append(candidate(last.profile.id, 0.99)) }

        let fused = PhotoEvidenceFusion.fuse(recognition: PhotoRecognition(candidates: photoCandidates), text: text, pack: pack,
                                             observationDescription: description)
        for match in fused.matches {
            if let textScore = textScores[match.species.id] {
                XCTAssertEqual(match.score, textScore, "confidence is the description's, unchanged")
            } else {
                XCTAssertLessThanOrEqual(match.score, LocalRankingWeights.limitedConfidenceCap)
            }
        }
        let photoOnlyIndex = try XCTUnwrap(fused.matches.firstIndex { $0.species.id == unranked.id })
        XCTAssertTrue(fused.matches[..<photoOnlyIndex].allSatisfy { textScores[$0.species.id] != nil },
                      "a photo-only species is ordered after every description-supported one")
        let boosted = try XCTUnwrap(fused.matches.first { $0.species.id == ranked.last?.profile.id })
        XCTAssertTrue(boosted.explanation.hasPrefix(PhotoMatchingWeights.explanation))
        XCTAssertNotNil(boosted.photoEvidence)
    }

    func testPhotoTermAddsOrderingWithinTheDescriptionTier() async throws {
        let pack = try await caribbean()
        let first = pack.profiles[0], second = pack.profiles[1]
        func textCandidate(_ profile: LocalSpeciesProfile, ordering: Double) -> DescriptionSearchCandidate {
            DescriptionSearchCandidate(profile: profile, rawScore: ordering, retrievalRelevance: nil, orderingScore: ordering, score: 0.7,
                                       matchedEvidence: ["color"], conflictingEvidence: [], informationLevel: .sufficient, matchedAppearanceVariant: nil)
        }
        let text = DescriptionSearchResult(candidates: [textCandidate(first, ordering: 20), textCandidate(second, ordering: 15)],
                                           queryAnalysis: .init(observedRegions: [], packRegionCompatibility: .unspecified),
                                           retrievedSpeciesIDs: [first.id, second.id], retrievalLimit: 2)
        let photoFirst = PhotoEvidenceFusion.fuse(recognition: PhotoRecognition(candidates: [candidate(second.id, 1.0)]), text: text, pack: pack)
        XCTAssertEqual(photoFirst.matches.map(\.species.id), [second.id, first.id], "15 + 8 × 1.0 outranks 20")
        XCTAssertEqual(photoFirst.matches.map(\.score), [0.7, 0.7])
        let weak = PhotoEvidenceFusion.fuse(recognition: PhotoRecognition(candidates: [candidate(second.id, 0.55)]), text: text, pack: pack)
        XCTAssertEqual(weak.matches.map(\.species.id), [first.id, second.id], "15 + 8 × 0.55 stays below 20")
    }

    func testAbstainingPhotoWithTextShowsTheDescriptionResultsUnchanged() async throws {
        let description = "Large flat eagle ray with white spots and a long tail over sand in the Caribbean."
        let pack = try await caribbean()
        let descriptionOnly = try await LocalMarineLifeIdentificationService(catalogRepository: repository(), parser: LocalObservationParser(), ranker: LocalSpeciesRanker())
            .identify(request: .init(source: .description(description), context: .init(region: .caribbean)), processedPhoto: nil)
        let outcome = try await identificationService(stub([candidate(pack.profiles[0].id, 0.1)]), features: debug)
            .identifyOutcome(request: photoRequest(notes: description), processedPhoto: photo)
        XCTAssertEqual(outcome.photoSummary?.abstained, true)
        XCTAssertEqual(outcome.photoSummary?.usedDescription, true)
        XCTAssertEqual(outcome.matches.map(\.species.id), descriptionOnly.map(\.species.id))
        XCTAssertEqual(outcome.matches.map(\.score), descriptionOnly.map(\.score))
    }

    func testRegionConflictInTheExtraTextIsReported() async throws {
        let pack = try await caribbean()
        do {
            _ = try await identificationService(stub([candidate(pack.profiles[0].id, 0.9)]), features: debug)
                .identifyOutcome(request: photoRequest(notes: "Blue striped fish seen in Fiji."), processedPhoto: photo)
            XCTFail("expected a region mismatch")
        } catch {
            guard case .regionMismatch = error as? LocalIdentificationError else { return XCTFail("\(error)") }
        }
    }

    // MARK: Coverage, stub, feedback and saving

    func testCoverageText() async throws {
        XCTAssertEqual(AppCopy.photoCoverage(covered: 3, total: 8),
                       "Photo matching covers 3 of 8 species. If you don't see it, try describing it.")
        let pack = try await caribbean()
        let ids = pack.profiles.map(\.id)
        let outcome = try await identificationService(stub([candidate(ids[0], 0.9)], covering: [ids[0], ids[1], UUID()]), features: debug)
            .identifyOutcome(request: photoRequest(), processedPhoto: photo)
        XCTAssertEqual(outcome.photoSummary?.coveredSpeciesCount, 2, "species outside the pack don't count")
        XCTAssertEqual(outcome.photoSummary?.catalogueSpeciesCount, pack.profiles.count)
    }

    func testDeterministicStubIsRepeatableAndCoversSpeciesWithPhotos() async throws {
        let pack = try await caribbean()
        let recognizer = StubPhotoRecognizer.deterministic(for: pack)
        XCTAssertEqual(recognizer.coveredSpeciesIDs, Set(pack.profiles.filter { $0.bundledImage != nil }.map(\.id)))
        let first = try await recognizer.recognize(photo, catalogueContentVersion: pack.photoCatalogueContentVersion)
        let again = try await recognizer.recognize(photo, catalogueContentVersion: pack.photoCatalogueContentVersion)
        XCTAssertEqual(first, again)
        XCTAssertFalse(first.candidates.isEmpty)
        XCTAssertTrue(first.candidates.allSatisfy { recognizer.coveredSpeciesIDs.contains($0.speciesID) })
        do {
            _ = try await recognizer.recognize(photo, catalogueContentVersion: "another-catalogue")
            XCTFail("a reference index for another catalogue must not be used")
        } catch {
            XCTAssertEqual(error as? PhotoRecognitionError, .catalogueVersionMismatch(expected: pack.photoCatalogueContentVersion, actual: "another-catalogue"))
        }
    }

    @MainActor
    func testPhotoResultsFeedFeedbackAndSave() async throws {
        let pack = try await repository().loadPack(id: .caribbean)
        let store = InMemoryIdentificationSessionStore()
        let request = photoRequest(notes: "  seen at night  ")
        _ = try await store.createSession(for: request, photo: photo)
        let repository = InMemoryDiverFeedbackRepository()
        let feedback = DiverFeedbackService(repository: repository, settings: InMemoryFeedbackSettings(), app: AppInfo(version: "0.5", build: "3", channel: "debug"))
        feedback.beginAttempt(sessionID: request.id, rawDescription: "  seen at night  ", pack: pack.metadata, previous: nil, source: .photo)

        let model = IdentificationResultsViewModel(sessionID: request.id, service: identificationService(stub([candidate(pack.profiles[0].id, 0.9)]), features: debug),
                                                   sessionStore: store, catalog: self.repository())
        await model.loadIfNeeded()
        guard case .loaded(let matches) = model.state else { return XCTFail("expected results, got \(model.state)") }
        XCTAssertEqual(model.photoCoverageText, AppCopy.photoCoverage(covered: 1, total: pack.profiles.count))
        XCTAssertEqual(matches.first?.sourceSessionID, request.id)

        let prompt = FeedbackPromptViewModel(sessionID: request.id, service: feedback)
        prompt.recordShown(matches, photo: model.photoSummary)
        prompt.choose(.notSure)
        await prompt.confirmConsent()
        await prompt.save()
        let records = try await repository.fetchAll()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.source, .photo)
        XCTAssertEqual(record.recognizerID, "stub")
        XCTAssertEqual(record.recognizerVersion, "1")
        XCTAssertEqual(record.originalDescription, "  seen at night  ")
        XCTAssertEqual(record.shownResults.map(\.speciesID), matches.map(\.species.id))
        let encoded = String(decoding: try DiverFeedbackExport.encoder.encode(record), as: UTF8.self)
        XCTAssertFalse(encoded.contains("previewData") || encoded.contains("uploadData"), "the photo is never stored in feedback")

        let saved = SavedIdentification(match: try XCTUnwrap(matches.first))
        XCTAssertEqual(saved.explanation, PhotoMatchingWeights.explanation)
        XCTAssertEqual(saved.sourceSessionID, request.id)
        let savedRepository = InMemorySavedIdentificationRepository()
        _ = try await savedRepository.save(saved)
        let stored = try await savedRepository.fetchAll()
        XCTAssertEqual(stored.map(\.species.id), [matches[0].species.id])
    }

    func testDescriptionFeedbackRecordsKeepTheDescriptionSource() async throws {
        let pack = try await caribbean()
        let feedback = await DiverFeedbackService(repository: InMemoryDiverFeedbackRepository(), settings: InMemoryFeedbackSettings())
        let attempt = await feedback.beginAttempt(sessionID: UUID(), rawDescription: "SYNTHETIC", pack: pack.metadata, previous: nil)
        XCTAssertEqual(attempt.source, .description)
        XCTAssertNil(attempt.recognizerID)
    }
}

/// Counts recognizer calls across concurrency domains.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
