import XCTest
@testable import DiveID

final class ProductionDescriptionSearchTests: XCTestCase {
    private let eagleRayDescription = "Large flat eagle ray with white spots and a long tail over sand in the Caribbean."
    private let barracudaDescription = "Long silver fish with a pointed head, large teeth and dark spots cruising near a Caribbean reef."
    private let parrotfishDescription = "Beaked reef grazer with a squared looking head in the Caribbean."

    private func repository() -> BundleMarineSpeciesCatalogRepository {
#if SWIFT_PACKAGE
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleThenDevelopmentSource)
#else
        BundleMarineSpeciesCatalogRepository(bundle: TestResources.productionBundle, resourceResolutionMode: .bundleOnly)
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
        XCTAssertNotNil(TestResources.productionBundle.url(forResource: "IdentificationPacks/Caribbean/PackManifest", withExtension: "json"))
        XCTAssertNotNil(TestResources.productionBundle.url(forResource: "IdentificationPacks/Caribbean/Creatures", withExtension: "json"))
#endif
        let pack = try await repository().loadPack(id: .caribbean)

        XCTAssertEqual(pack.metadata.id, .caribbean)
        XCTAssertEqual(pack.metadata.speciesCount, 8)
        XCTAssertEqual(pack.profiles.count, 8)
        XCTAssertEqual(Set(pack.profiles.map(\.id)).count, 8)
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
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func repository(root: URL) -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(
            bundle: Bundle(for: CatalogueDiagnosticsTests.self),
            resourceResolutionMode: .bundleThenDevelopmentSource,
            developmentSourceRoot: root
        )
    }

    private func copyProductionResources(to root: URL, includeImages: Bool = false) throws -> URL {
        let source = URL(fileURLWithPath: "DiveID/Resources/IdentificationPacks/Caribbean", isDirectory: true)
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
        try Data(contentsOf: URL(fileURLWithPath: "DiveID/Resources/IdentificationPacks/Caribbean/PackManifest.json"))
            .write(to: directory.appendingPathComponent("PackManifest.json"))
        await assertFailure(root: root, code: .speciesResourceMissing, resource: "IdentificationPacks/Caribbean/Creatures.json", phase: .speciesResource)
    }

    func testMalformedSpeciesJSONReportsDecodeFailure() async throws {
        let root = try temporaryRoot()
        let directory = root.appendingPathComponent("IdentificationPacks/Caribbean", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: URL(fileURLWithPath: "DiveID/Resources/IdentificationPacks/Caribbean/PackManifest.json"))
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
