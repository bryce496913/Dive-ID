import Foundation
import XCTest
@testable import DiveID

final class SavedIdentificationCompatibilityTests: XCTestCase {
    func testSchema1FixtureDecodesAndPreservesSpeciesIdentity() async throws {
        let (repository, directory, _) = try repository(for: "Schema1")
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = try XCTUnwrap(try await repository.fetchAll().first)
        XCTAssertEqual(saved.species.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        XCTAssertEqual(saved.species.commonName, "Queen Angelfish")
    }

    func testSchema2HistoricalFixturePreservesIdentificationAndEvidence() async throws {
        let (repository, directory, _) = try repository(for: "Schema2Historical")
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = try XCTUnwrap(try await repository.fetchAll().first)
        XCTAssertEqual(saved.id, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(saved.species.id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(saved.sourceSessionID, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        XCTAssertEqual(saved.observationDescription, "Large dark ray with white spots swimming over sand")
        XCTAssertEqual(saved.explanation, "The spots and wing-shaped body support this match.")
        XCTAssertEqual(saved.distinguishingFeatures, ["Rows of white dorsal spots", "Flattened duckbill snout"])
        XCTAssertEqual(saved.cautions, ["Do not touch or chase wildlife"])
        XCTAssertEqual(saved.match.observationDescription, saved.observationDescription)
        XCTAssertEqual(saved.match.explanation, saved.explanation)
    }

    func testHistoricalSpeciesMissingEnrichmentUsesSafeDefaults() async throws {
        let (repository, directory, _) = try repository(for: "Schema2Historical")
        defer { try? FileManager.default.removeItem(at: directory) }

        let species = try XCTUnwrap(try await repository.fetchAll().first?.species)
        XCTAssertNil(species.bundledImage)
        XCTAssertNil(species.packContext)
        XCTAssertNil(species.regionalOccurrence)
        XCTAssertNil(species.regionalOccurrenceNotes)
        XCTAssertEqual(species.subregions, [])
        XCTAssertEqual(species.appearanceVariants, [])
        XCTAssertEqual(species.similarSpecies, [])
        XCTAssertEqual(species.aliases, [])
        XCTAssertEqual(species.categories, [])
        XCTAssertEqual(species.colors, [])
        XCTAssertEqual(species.markings, [])
        XCTAssertEqual(species.bodyShapes, [])
        XCTAssertEqual(species.habitats, [])
        XCTAssertEqual(species.regions, [])
        XCTAssertEqual(species.behaviors, [])
        XCTAssertEqual(species.keywords, [])
        XCTAssertNil(species.minimumSizeCentimeters)
        XCTAssertNil(species.maximumSizeCentimeters)
        XCTAssertNil(species.minimumDepthMeters)
        XCTAssertNil(species.maximumDepthMeters)
        XCTAssertEqual(species.cautions, [])
        XCTAssertEqual(species.dataSources, [])
        XCTAssertNil(species.review)
    }

    func testCurrentSchemaFixtureDecodes() async throws {
        let (repository, directory, _) = try repository(for: "CurrentSchema")
        defer { try? FileManager.default.removeItem(at: directory) }

        let saved = try XCTUnwrap(try await repository.fetchAll().first)
        XCTAssertEqual(saved.id, UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        XCTAssertEqual(saved.species.categories, ["shark"])
        XCTAssertEqual(saved.observationDescription, "Gray shark cruising beside a coral wall")
    }

    func testOpeningHistoricalSaveRestoresMatchWithoutIdentificationService() async throws {
        let (repository, directory, _) = try repository(for: "Schema2Historical")
        defer { try? FileManager.default.removeItem(at: directory) }

        let restored = try XCTUnwrap(try await repository.fetchAll().first).match
        XCTAssertEqual(restored.id, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        XCTAssertEqual(restored.rank, 2)
        XCTAssertEqual(restored.score, 0.74)
        XCTAssertEqual(restored.strength, .good)
        XCTAssertEqual(restored.sourceSessionID, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
    }

    func testCorruptFixtureRetainsSafeCorruptionBehavior() async throws {
        let (repository, directory, fileURL) = try repository(for: "Corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalData = try Data(contentsOf: fileURL)

        do {
            _ = try await repository.fetchAll()
            XCTFail("Expected corrupt data error")
        } catch SavedIdentificationRepositoryError.corruptData {
            XCTAssertEqual(try Data(contentsOf: fileURL), originalData)
        }
    }

    func testFutureSchemaFixtureRetainsUnsupportedSchemaBehavior() async throws {
        let (repository, directory, _) = try repository(for: "FutureSchema")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await repository.fetchAll()
            XCTFail("Expected unsupported schema error")
        } catch SavedIdentificationRepositoryError.unsupportedSchema {
            // Expected: future data must not be interpreted as the current schema.
        }
    }

    func testSchema1MigrationReencodesCurrentFormatAndRelaunches() async throws {
        let (repository, directory, fileURL) = try repository(for: "Schema1")
        defer { try? FileManager.default.removeItem(at: directory) }

        let migrated = try XCTUnwrap(try await repository.fetchAll().first)
        let envelope = try JSONDecoder().decode(SavedIdentificationFile.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(envelope.schemaVersion, JSONSavedIdentificationRepository.schemaVersion)
        XCTAssertEqual(envelope.identifications.first?.id, migrated.id)
        XCTAssertEqual(envelope.identifications.first?.species.id, migrated.species.id)

        let relaunched = try JSONSavedIdentificationRepository(fileURL: fileURL)
        let restored = try XCTUnwrap(try await relaunched.fetchAll().first)
        XCTAssertEqual(restored.id, migrated.id)
        XCTAssertEqual(restored.species.id, migrated.species.id)
    }

    private func repository(for fixtureName: String) throws -> (JSONSavedIdentificationRepository, URL, URL) {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SavedIdentifications/\(fixtureName).json")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("saved-identifications.json")
        try FileManager.default.copyItem(at: fixtureURL, to: fileURL)
        return (try JSONSavedIdentificationRepository(fileURL: fileURL), directory, fileURL)
    }
}
