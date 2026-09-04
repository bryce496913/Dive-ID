import XCTest
@testable import DiveID

final class ProductionDescriptionSearchTests: XCTestCase {
    private let eagleRayDescription = "Large flat eagle ray with white spots and a long tail over sand in the Caribbean."
    private let barracudaDescription = "Long silver fish with a pointed head, large teeth and dark spots cruising near a Caribbean reef."
    private let parrotfishDescription = "Beaked reef grazer with a squared looking head in the Caribbean."

    private func repository() -> BundleMarineSpeciesCatalogRepository {
        BundleMarineSpeciesCatalogRepository(bundle: Bundle(for: Self.self))
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
