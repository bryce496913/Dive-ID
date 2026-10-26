import XCTest
@testable import DiveID

final class ProductionDescriptionSearchTests: XCTestCase {
    private let eagleRayDescription = "Large flat eagle ray with white spots and a long tail over sand in the Caribbean."
    private let barracudaDescription = "Long silver fish with a pointed head, large teeth and dark spots cruising near a Caribbean reef."
    private let parrotfishDescription = "Beaked reef grazer with a squared looking head in the Caribbean."

    private func repository() -> BundleMarineSpeciesCatalogRepository {
#if SWIFT_PACKAGE
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource, access: .experimentalDevelopment)
#else
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
#endif
    }

    private func service() -> LocalMarineLifeIdentificationService {
        LocalMarineLifeIdentificationService(
            catalogRepository: repository(),
            parser: LocalObservationParser(),
            ranker: LocalSpeciesRanker()
        )
    }

    private func search(_ description: String) async throws -> [IdentificationMatch] {
        try await service().identify(
            request: IdentificationRequest(
                source: .description(description),
                context: .init(region: .caribbean)
            ),
            processedPhoto: nil
        )
    }

    func testProductionCaribbeanPackLoadsWithExpectedRecords() async throws {
#if !SWIFT_PACKAGE
        XCTAssertNotNil(TestResources.productionBundle.url(forResource: "PackManifest", withExtension: "json", subdirectory: "IdentificationPacks/Caribbean"))
        XCTAssertNotNil(TestResources.productionBundle.url(forResource: "Creatures", withExtension: "json", subdirectory: "IdentificationPacks/Caribbean"))
#endif
        let pack = try await repository().loadPack(id: .caribbean)

        XCTAssertEqual(pack.metadata.id, .caribbean)
        XCTAssertEqual(pack.metadata.speciesCount, 8)
        XCTAssertEqual(pack.profiles.count, 8)
        XCTAssertEqual(Set(pack.profiles.map(\.id)).count, 8)
#if !SWIFT_PACKAGE
        for profile in pack.profiles {
            if let image = profile.bundledImage {
                XCTAssertNotNil(TestResources.productionBundle.url(forResource: image.fileName, withExtension: nil, subdirectory: "IdentificationPacks/Caribbean/Images"))
            }
        }
#endif
    }

    func testEagleRayQueryReturnsSpottedEagleRayFirst() async throws {
        let matches = try await search(eagleRayDescription)

        XCTAssertEqual(matches.first?.species.commonName, "Spotted Eagle Ray")
    }

    func testBarracudaQueryReturnsGreatBarracudaInTopResults() async throws {
        let matches = try await search(barracudaDescription)

        XCTAssertTrue(matches.prefix(3).contains { $0.species.commonName == "Great Barracuda" })
    }

    func testParrotfishQueryMeetsExistingTopThreeBenchmarkExpectation() async throws {
        let matches = try await search(parrotfishDescription)

        XCTAssertTrue(matches.prefix(3).contains { $0.species.commonName == "Stoplight Parrotfish" })
    }

    func testDifferentQueriesProduceDifferentOrderedResultIDs() async throws {
        let descriptions = [eagleRayDescription, barracudaDescription, parrotfishDescription]
        let results = try await descriptions.asyncMap { try await self.search($0) }
        let orderings = results.map { $0.map(\.id) }

        XCTAssertEqual(Set(orderings).count, descriptions.count)
        for (description, matches) in zip(descriptions, results) {
            print("PRODUCTION_SEARCH_ORDER \(description) => \(matches.map(\.species.commonName).joined(separator: " | "))")
        }
    }

    func testProductionResultsAreLimitedAndHaveUniqueSpeciesIDs() async throws {
        for description in [eagleRayDescription, barracudaDescription, parrotfishDescription] {
            let matches = try await search(description)
            XCTAssertLessThanOrEqual(matches.count, 10, description)
            XCTAssertEqual(Set(matches.map(\.species.id)).count, matches.count, description)
        }
    }

    func testValidProductionDescriptionsNeverReportCatalogUnavailable() async throws {
        for description in [eagleRayDescription, barracudaDescription, parrotfishDescription] {
            do {
                let matches = try await search(description)
                XCTAssertFalse(matches.isEmpty, description)
            } catch LocalIdentificationError.catalogUnavailable {
                XCTFail("The production Caribbean catalogue was unavailable for: \(description)")
            }
        }
    }

    func testProductionSearchIsDeterministicAcrossRepeatedRuns() async throws {
        for description in [eagleRayDescription, barracudaDescription, parrotfishDescription] {
            let first = try await search(description)
            let second = try await search(description)
            XCTAssertEqual(first.map(\.id), second.map(\.id), description)
            XCTAssertEqual(first.map(\.score), second.map(\.score), description)
        }
    }

    func testExistingRequestErrorsRemainUnchanged() async throws {
        do {
            _ = try await search("   ")
            XCTFail("Expected an invalid-description error")
        } catch {
            XCTAssertEqual(error as? LocalIdentificationError, .invalidDescription)
        }

        do {
            _ = try await service().identify(
                request: IdentificationRequest(source: .processedPhoto(.init(id: UUID()))),
                processedPhoto: nil
            )
            XCTFail("Expected an unsupported-source error")
        } catch {
            XCTAssertEqual(error as? LocalIdentificationError, .unsupportedSource)
        }

        do {
            _ = try await search("Long colorful fish swimming on an Indo-Pacific reef near Fiji.")
            XCTFail("Expected a region-mismatch error")
        } catch let error as LocalIdentificationError {
            guard case .regionMismatch(let selected, _) = error else {
                return XCTFail("Expected region mismatch, received \(error)")
            }
            XCTAssertEqual(selected, .caribbean)
        }
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self {
            try await values.append(transform(element))
        }
        return values
    }
}

final class CatalogueDiagnosticsTests: XCTestCase {
    private let partialApprovalID = OfflineIdentificationPackID(rawValue: "partial-approval-fixture")

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func repository(root: URL) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: CatalogueDiagnosticsTests.self),
            resourceResolutionMode: .bundleThenDevelopmentSource,
            developmentSourceRoot: root,
            access: .experimentalDevelopment
        )
    }

    private func partialApprovalRepository(access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) -> BundleMarineSpeciesCatalogRepository {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
        return BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: CatalogueDiagnosticsTests.self),
            registry: RegionCatalogRegistry(definitions: [
                RegionCatalogDefinition(id: partialApprovalID, resourceDirectory: "PartialApproval")
            ]),
            resourceResolutionMode: .bundleThenDevelopmentSource,
            developmentSourceRoot: fixtures,
            access: access
        )
    }

    private func copyProductionResources(to root: URL, includeImages: Bool = false) throws -> URL {
        let source = try XCTUnwrap(TestResources.productionBundle.resourceURL).appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        let destination = root.appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in ["PackManifest.json", "Creatures.json"] {
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
        }
        if includeImages {
            try FileManager.default.copyItem(at: source.appendingPathComponent("Images"), to: destination.appendingPathComponent("Images"))
        }
        return destination
    }

    private func assertFailure(
        root: URL,
        code: CatalogueDiagnosticCode,
        resource: String,
        phase: CatalogueLoadPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await repository(root: root).loadPack(id: .caribbean)
            XCTFail("Expected catalogue load failure", file: file, line: line)
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.packID, .caribbean, file: file, line: line)
            XCTAssertEqual(failure.code, code, file: file, line: line)
            XCTAssertEqual(failure.resource, resource, file: file, line: line)
            XCTAssertEqual(failure.phase, phase, file: file, line: line)
            XCTAssertNotNil(failure.catalogError, file: file, line: line)
            XCTAssertFalse(failure.resource?.hasPrefix("/") == true, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testMissingManifestRetainsPackAndLogicalResource() async throws {
        let root = try temporaryRoot()
        await assertFailure(root: root, code: .manifestMissing, resource: "IdentificationPacks/Caribbean/PackManifest.json", phase: .manifest)
    }

    func testMissingSpeciesResourceHasStableDiagnostic() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: try XCTUnwrap(TestResources.productionBundle.url(forResource: "PackManifest", withExtension: "json", subdirectory: "IdentificationPacks/Caribbean")))
            .write(to: directory.appendingPathComponent("PackManifest.json"))
        await assertFailure(root: root, code: .speciesResourceMissing, resource: "IdentificationPacks/Caribbean/Creatures.json", phase: .speciesResource)
    }

    func testMalformedSpeciesJSONReportsDecodeFailure() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: try XCTUnwrap(TestResources.productionBundle.url(forResource: "PackManifest", withExtension: "json", subdirectory: "IdentificationPacks/Caribbean")))
            .write(to: directory.appendingPathComponent("PackManifest.json"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("Creatures.json"))
        await assertFailure(root: root, code: .decodeFailed, resource: "IdentificationPacks/Caribbean/Creatures.json", phase: .decoding)
    }

    func testCountMismatchHasStableDiagnostic() async throws {
        let root = try temporaryRoot()
        let directory = try copyProductionResources(to: root)
        let manifestURL = directory.appendingPathComponent("PackManifest.json")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8).replacingOccurrences(of: "\"speciesCount\": 8", with: "\"speciesCount\": 9")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        await assertFailure(root: root, code: .countMismatch, resource: "IdentificationPacks/Caribbean/Creatures.json", phase: .validation)
    }

    func testMissingPublicationAccountingFailsClosed() async throws {
        let root = try temporaryRoot()
        let directory = try copyProductionResources(to: root, includeImages: true)
        let manifestURL = directory.appendingPathComponent("PackManifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object.removeValue(forKey: "includedRecordCount")
        object.removeValue(forKey: "humanReviewedRecordCount")
        object.removeValue(forKey: "publicationEligibleRecordCount")
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        do {
            _ = try await repository(root: root).loadPack(id: .caribbean)
            XCTFail("Missing accounting must not imply approval")
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .reviewAccountingInvalid)
            XCTAssertEqual(failure.catalogError, .reviewAccountingInvalid)
        }
    }

    func testExplicitAllDraftFixtureIsUnavailableForPublication() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try copyProductionResources(to: root, includeImages: true)
        let speciesURL = directory.appendingPathComponent("Creatures.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: speciesURL)) as? [[String: Any]])
        for index in records.indices { records[index]["review"] = ["status": "draft"] }
        try JSONSerialization.data(withJSONObject: records).write(to: speciesURL)
        let manifestURL = directory.appendingPathComponent("PackManifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["humanReviewedRecordCount"] = 0
        manifest["publicationEligibleRecordCount"] = 0
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let publication = BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: CatalogueDiagnosticsTests.self),
            registry: RegionCatalogRegistry(definitions: [RegionCatalogDefinition(id: .caribbean, resourceDirectory: "Caribbean")]),
            resourceResolutionMode: .bundleThenDevelopmentSource, developmentSourceRoot: root, access: .publication)
        let available = try await publication.availablePacks()
        XCTAssertTrue(available.isEmpty)
        do {
            _ = try await publication.loadPack(id: .caribbean)
            XCTFail("All-draft fixture must remain unavailable")
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .publicationUnavailable)
        }
    }

    func testPublicationAccessReturnsOnlySyntheticVerifiedFixture() async throws {
        let root = try temporaryRoot()
        let directory = try copyProductionResources(to: root, includeImages: true)
        let speciesURL = directory.appendingPathComponent("Creatures.json")
        var records = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: speciesURL)) as? [[String: Any]])
        // Explicitly synthetic: future real promotions must not alter this fixture.
        for index in records.indices { records[index]["review"] = ["status": "draft"] }
        records[0]["review"] = [
            "status": "verified", "reviewerNotes": "Synthetic gate fixture only",
            "reviewDate": "2026-09-24T00:00:00Z", "verifiedBy": "Synthetic test reviewer"
        ]
        try JSONSerialization.data(withJSONObject: records).write(to: speciesURL)
        let manifestURL = directory.appendingPathComponent("PackManifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["humanReviewedRecordCount"] = 1
        manifest["publicationEligibleRecordCount"] = 1
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        // An unretired definition of the copied pack: the publication filter is what is under test.
        let publicationRepository = BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: CatalogueDiagnosticsTests.self),
            registry: RegionCatalogRegistry(definitions: [RegionCatalogDefinition(id: .caribbean, resourceDirectory: "Caribbean")]),
            resourceResolutionMode: .bundleThenDevelopmentSource,
            developmentSourceRoot: root,
            access: .publication
        )
        let pack = try await publicationRepository.loadPack(id: .caribbean)
        XCTAssertEqual(pack.profiles.count, 1)
        XCTAssertEqual(pack.profiles.first?.review?.status, .verified)
        XCTAssertEqual(pack.metadata.publicationEligibleRecordCount, 1)
    }

    func testRepositoryFixturePreservesFullAccountingAcrossDevelopmentAndPublicationFiltering() async throws {
        let development = partialApprovalRepository(access: .experimentalDevelopment)
        let developmentPack = try await development.loadPack(id: partialApprovalID)
        XCTAssertEqual(developmentPack.profiles.count, 4)
        XCTAssertEqual(developmentPack.metadata.availableRecordCount, 4)
        XCTAssertEqual(developmentPack.metadata.includedRecordCount, 4)
        XCTAssertEqual(developmentPack.metadata.approvedRecordCount, 1)
        XCTAssertEqual(developmentPack.metadata.draftRecordCount, 3)
        XCTAssertEqual(developmentPack.metadata.publicationStatusText, "4 records available — 1 approved and 3 draft")
        XCTAssertTrue(developmentPack.metadata.isExperimental)

        let publication = partialApprovalRepository(access: .publication)
        let available = try await publication.availablePacks()
        let region = try XCTUnwrap(available.first { $0.id == partialApprovalID })
        XCTAssertEqual(region.availableRecordCount, 1)
        XCTAssertEqual(region.includedRecordCount, 4, "Full-pack accounting must remain traceable")
        XCTAssertEqual(region.publicationStatusText, "1 approved record available (3 draft records excluded)")
        XCTAssertFalse(region.isExperimental)

        let publicationPack = try await publication.loadPack(id: partialApprovalID)
        XCTAssertEqual(publicationPack.profiles.count, 1)
        XCTAssertEqual(publicationPack.metadata.speciesCount, 1)
        XCTAssertEqual(publicationPack.metadata.includedRecordCount, 4)
        XCTAssertTrue(publicationPack.profiles.allSatisfy { $0.review?.status == .verified })

        let draftIDs = Set(developmentPack.profiles.filter { $0.review?.status == .draft }.map(\.id))
        let service = LocalMarineLifeIdentificationService(catalogRepository: publication)
        let candidates = try await service.identify(
            request: IdentificationRequest(
                source: .description("Atlantic blue tang reef fish"),
                context: .init(region: partialApprovalID)
            ),
            processedPhoto: nil
        )
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(draftIDs.isDisjoint(with: candidates.map(\.species.id)), "Draft IDs must not enter Release search candidates")
    }

    func testInconsistentPartialApprovalFixtureAccountingFailsClosed() async throws {
        let root = try temporaryRoot()
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/IdentificationPacks/PartialApproval", isDirectory: true)
        let destination = root.appendingPathComponent("IdentificationPacks/PartialApproval", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: destination)
        let manifestURL = destination.appendingPathComponent("PackManifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        manifest["publicationEligibleRecordCount"] = 2
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let repository = BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: CatalogueDiagnosticsTests.self),
            registry: RegionCatalogRegistry(definitions: [RegionCatalogDefinition(id: partialApprovalID, resourceDirectory: "PartialApproval")]),
            resourceResolutionMode: .bundleThenDevelopmentSource,
            developmentSourceRoot: root,
            access: .publication
        )
        do {
            _ = try await repository.loadPack(id: partialApprovalID)
            XCTFail("Inconsistent accounting must fail closed")
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .reviewAccountingInvalid)
            XCTAssertEqual(failure.catalogError, .reviewAccountingInvalid)
            XCTAssertEqual(failure.phase, .validation)
        }
    }

    func testVocabularyErrorHasStableDiagnostic() async throws {
        let root = try temporaryRoot()
        let directory = try copyProductionResources(to: root)
        let speciesURL = directory.appendingPathComponent("Creatures.json")
        let species = try String(contentsOf: speciesURL, encoding: .utf8).replacingOccurrences(of: "\"blue\"", with: "\"ultraviolet-test-color\"")
        try species.write(to: speciesURL, atomically: true, encoding: .utf8)
        await assertFailure(root: root, code: .vocabularyInvalid, resource: "IdentificationPacks/Caribbean/Creatures.json", phase: .validation)
    }

    func testMissingArtworkRetainsLogicalArtworkResource() async throws {
        let root = try temporaryRoot()
        _ = try copyProductionResources(to: root)
        do {
            _ = try await repository(root: root).loadPack(id: .caribbean)
            XCTFail("Expected missing artwork")
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .artworkMissing)
            XCTAssertEqual(failure.phase, .artworkValidation)
            XCTAssertTrue(failure.resource?.hasPrefix("IdentificationPacks/Caribbean/Images/") == true)
            XCTAssertFalse(failure.resource?.hasPrefix("/") == true)
        }
    }

    func testInvalidArtworkHasStableDiagnosticAndLogicalResource() async throws {
        let root = try temporaryRoot()
        let directory = try copyProductionResources(to: root, includeImages: true)
        let imageURL = directory.appendingPathComponent("Images/fc213eff-6ba6-53ab-b288-f6e654299e68.svg")
        try Data("not an svg".utf8).write(to: imageURL)
        do {
            _ = try await repository(root: root).loadPack(id: .caribbean)
            XCTFail("Expected invalid artwork")
        } catch let failure as CatalogueLoadFailure {
            XCTAssertEqual(failure.code, .artworkInvalid)
            XCTAssertEqual(failure.phase, .artworkValidation)
            XCTAssertEqual(failure.resource, "IdentificationPacks/Caribbean/Images/fc213eff-6ba6-53ab-b288-f6e654299e68.svg")
        }
    }

    func testServicePreservesTypedCatalogueFailure() async throws {
        let expected = CatalogueLoadFailure(packID: .caribbean, code: .countMismatch, catalogError: .countMismatch(expected: 8, actual: 7), resource: "IdentificationPacks/Caribbean/Creatures.json", phase: .validation)
        let service = LocalMarineLifeIdentificationService(catalogRepository: FailingCatalogueRepository(error: expected))
        do {
            _ = try await service.identify(request: .init(source: .description("striped reef fish"), context: .init(region: .caribbean)), processedPhoto: nil)
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? LocalIdentificationError, .catalogueLoadFailed(expected))
        }
    }
}

private struct FailingCatalogueRepository: MarineSpeciesCatalogRepository {
    let error: any Error
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { throw error }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { throw error }
}

final class DomainEligibilityTests: XCTestCase {
    private func repository() -> BundleMarineSpeciesCatalogRepository {
        .init(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .experimentalDevelopment)
    }

    func testDomainContradictionRejectsCandidatesInBothEnginesAndPacks() async throws {
        for packID in [OfflineIdentificationPackID.caribbean, .tropicalPacific] {
            let pack = try await repository().loadPack(id: packID)
            for engine: any DescriptionSearching in [HybridDescriptionSearchEngine(), StructuredDescriptionSearchEngine()] {
                let result = try await engine.search(description: "A spotted freshwater frog swimming on sand, about 5 cm long.", pack: pack)
                XCTAssertFalse(result.retrievedSpeciesIDs.isEmpty)
                XCTAssertTrue(result.candidates.isEmpty)
                XCTAssertEqual(result.diagnostics.disposition, .allCandidatesRejectedByRanker)
                XCTAssertEqual(result.queryAnalysis.packRegionCompatibility, .unspecified)
            }
        }
    }

    func testExactNameAndStrongSemanticRetrievalCannotOverrideSubjectContradiction() async throws {
        let pack = try await repository().loadPack(id: .caribbean)
        let profile = try XCTUnwrap(pack.profiles.first)
        let description = "A spotted frog beside a sign reading \(profile.commonName)."
        let observation = await LocalObservationParser().parse(description)
        XCTAssertEqual(observation.domainContradiction, .amphibianSubject)
        let result = try await LocalSpeciesRanker().rank(input: .init(description: description, observation: observation, candidates: [
            .init(speciesID: profile.id, profile: profile, retrieval: .init(source: .semantic, scoreKind: .cosineSimilarity, score: 1, rank: 1, evidence: []))
        ]))
        XCTAssertTrue(result.isEmpty)
    }

    func testNearbyMarineDescriptionsRemainEligible() async throws {
        let pack = try await repository().loadPack(id: .caribbean)
        for engine: any DescriptionSearching in [HybridDescriptionSearchEngine(), StructuredDescriptionSearchEngine()] {
            for description in [
                "Not a frog. A large flat eagle ray with white spots and a long tail over sand.",
                "A frog-like face on a long silver fish with large teeth and dark spots near a reef.",
                "A long silver fish eating a frog, with large teeth and dark spots near a reef.",
                "A large flat eagle ray with white spots and an unfamiliar glorp near its long tail over sand."
            ] {
                let result = try await engine.search(description: description, pack: pack)
                XCTAssertFalse(result.candidates.isEmpty, description)
            }
        }
    }

    func testNoMatchRegionMismatchAndLoadFailureRemainDistinct() async throws {
        let service = LocalMarineLifeIdentificationService(catalogRepository: repository())
        let description = "A spotted freshwater frog swimming over sand."
        let matches = try await service.identify(request: .init(source: .description(description), context: .init(region: .caribbean)), processedPhoto: nil)
        XCTAssertTrue(matches.isEmpty)
        do {
            _ = try await service.identify(request: .init(source: .description(description + " In Fiji."), context: .init(region: .caribbean)), processedPhoto: nil)
            XCTFail("Expected region mismatch even when domain evidence rejects candidates")
        } catch LocalIdentificationError.regionMismatch(let selected, _) {
            XCTAssertEqual(selected, .caribbean)
        }
        let broken = LocalMarineLifeIdentificationService(catalogRepository: UnreadableDomainTestRepository())
        do {
            _ = try await broken.identify(request: .init(source: .description(description), context: .init(region: .caribbean)), processedPhoto: nil)
            XCTFail("Storage failure must not become successful no-match")
        } catch LocalIdentificationError.catalogueLoadFailed(let failure) {
            XCTAssertEqual(failure.catalogError, .unreadableData)
        }
    }
}

private struct UnreadableDomainTestRepository: MarineSpeciesCatalogRepository {
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [] }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack {
        throw LocalCatalogError.unreadableData
    }
}

/// A diver who types only an animal group ("shark", "rays") gets that group's species from
/// the Release Global pack, at limited confidence. "Fish" and vague phrases still list nothing.
final class AnimalGroupSearchTests: XCTestCase {
    private func releaseGlobal() async throws -> OfflineIdentificationPack {
        try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: .publication).loadPack(id: .global)
    }

    private func search(_ description: String, in pack: OfflineIdentificationPack) async throws -> [IdentificationMatch] {
        try await LocalMarineLifeIdentificationService(catalogRepository: SinglePackRepository(pack: pack), parser: LocalObservationParser(), ranker: LocalSpeciesRanker())
            .identify(request: IdentificationRequest(source: .description(description), context: .init(region: .global)), processedPhoto: nil)
    }

    func testGroupNameAloneListsThatGroupFromReleaseGlobal() async throws {
        let pack = try await releaseGlobal()
        let categories = Dictionary(uniqueKeysWithValues: pack.profiles.map { ($0.id, Set($0.categories)) })
        XCTAssertGreaterThanOrEqual(pack.profiles.filter { $0.categories.contains("shark") }.count, 80)
        XCTAssertGreaterThanOrEqual(pack.profiles.filter { $0.categories.contains("ray") }.count, 60)
        for (description, group) in [("shark", "shark"), ("Sharks", "shark"), ("ray", "ray"), ("rays", "ray"), ("stingray", "ray"), ("manta", "ray")] {
            let matches = try await search(description, in: pack)
            XCTAssertFalse(matches.isEmpty, description)
            for match in matches {
                XCTAssertTrue(categories[match.id]?.contains(group) ?? false, "\(description): \(match.species.commonName) is not a \(group)")
                XCTAssertLessThanOrEqual(match.score, 0.64, "\(description): a group name alone is limited evidence")
            }
            if description == "manta" { XCTAssertTrue(matches.contains { $0.species.commonName == "Oceanic manta ray" }, description) }
        }
        let whale = try await search("whale shark", in: pack)
        XCTAssertEqual(whale.first?.species.commonName, "Whale shark")
    }

    func testBroadOrVagueDescriptionsStillListNothing() async throws {
        let pack = try await releaseGlobal()
        for description in ["fish", "dark fish", "blue thing"] {
            let matches = try await search(description, in: pack)
            XCTAssertTrue(matches.isEmpty, "\(description): \(matches.map(\.species.commonName))")
        }
    }

    /// "Flat thing" was already limited information before group-name searches: the parser
    /// reads it as body shape "flat" plus category "ray", two clue groups with a distinctive
    /// one. It lists rays at limited confidence, as it did before.
    func testFlatThingListsRaysAtLimitedConfidence() async throws {
        let pack = try await releaseGlobal()
        let rays = Set(pack.profiles.filter { $0.categories.contains("ray") }.map(\.id))
        let matches = try await search("flat thing", in: pack)
        XCTAssertFalse(matches.isEmpty)
        for match in matches {
            XCTAssertTrue(rays.contains(match.id), match.species.commonName)
            XCTAssertLessThanOrEqual(match.score, 0.64, match.species.commonName)
        }
    }

    func testThreeLetterGroupNamesCanBeSubmitted() async throws {
        let pack = try await releaseGlobal()
        let matches = try await search("eel", in: pack)
        XCTAssertFalse(matches.isEmpty)
        do {
            _ = try await search("ab", in: pack)
            XCTFail("Expected an invalid-description error")
        } catch {
            XCTAssertEqual(error as? LocalIdentificationError, .invalidDescription)
        }
    }
}

/// The four sharks and rays Bryce asked for on 2026-10-23 (Data/GlobalMarine/OwnerAdditions.csv,
/// Global batch-21, approved by Bryce the same day) are found by name in Debug and in Release.
/// "Grey reef shark" was an alias on Graceful shark and Silky shark; it now names only the real species.
final class OwnerAddedSpeciesSearchTests: XCTestCase {
    private func global(_ access: BundleMarineSpeciesCatalogRepository.CatalogueAccess) async throws -> OfflineIdentificationPack {
        try await BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly, access: access).loadPack(id: .global)
    }

    private func search(_ description: String, in pack: OfflineIdentificationPack) async throws -> [IdentificationMatch] {
        try await LocalMarineLifeIdentificationService(catalogRepository: SinglePackRepository(pack: pack), parser: LocalObservationParser(), ranker: LocalSpeciesRanker())
            .identify(request: IdentificationRequest(source: .description(description), context: .init(region: .global)), processedPhoto: nil)
    }

    private let added = ["Whitetip reef shark": "Triaenodon obesus", "Grey reef shark": "Carcharhinus amblyrhynchos",
                         "Zebra shark": "Stegostoma tigrinum", "Reef manta ray": "Mobula alfredi"]

    func testEachAddedSpeciesIsFoundByNameInDevelopmentAndRelease() async throws {
        for access in [BundleMarineSpeciesCatalogRepository.CatalogueAccess.experimentalDevelopment, .publication] {
            let pack = try await global(access)
            for (description, expected) in [("Whitetip reef shark", "Whitetip reef shark"), ("grey reef shark", "Grey reef shark"),
                                            ("gray reef shark", "Grey reef shark"), ("zebra shark", "Zebra shark"), ("reef manta", "Reef manta ray")] {
                let matches = try await search(description, in: pack)
                XCTAssertEqual(matches.first?.species.commonName, expected, "\(access) \(description): \(matches.prefix(3).map(\.species.commonName))")
                XCTAssertEqual(matches.first?.species.scientificName, added[expected], description)
            }
        }
    }

    func testGreyReefSharkNamesNoOtherSpecies() async throws {
        let pack = try await global(.experimentalDevelopment)
        let owners = pack.profiles.filter { profile in
            profile.aliases.contains { ["grey reef shark", "gray reef shark"].contains($0.lowercased()) } || profile.commonName == "Grey reef shark"
        }
        XCTAssertEqual(owners.map(\.scientificName), ["Carcharhinus amblyrhynchos"])
    }

    func testAddedSpeciesAreApprovedAndInRelease() async throws {
        let development = try await global(.experimentalDevelopment)
        let additions = development.profiles.filter { added[$0.commonName] == $0.scientificName }
        XCTAssertEqual(additions.count, added.count)
        let releaseIDs = Set(try await global(.publication).profiles.map(\.id))
        for profile in additions {
            XCTAssertEqual(profile.review?.status, .verified, profile.commonName)
            XCTAssertEqual(profile.review?.reviewMethod, .individuallyReviewed, profile.commonName)
            XCTAssertTrue(releaseIDs.contains(profile.id), profile.commonName)
        }
    }
}

private struct SinglePackRepository: MarineSpeciesCatalogRepository {
    let pack: OfflineIdentificationPack
    func availablePacks() async throws -> [OfflineIdentificationPackMetadata] { [pack.metadata] }
    func loadPack(id: OfflineIdentificationPackID) async throws -> OfflineIdentificationPack { pack }
}
